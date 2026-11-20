import hashlib
import json
import os
import pathlib
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from store_guest_packaging import HELPER_NAME, NOTICES, _checked_file, copy_pinned_assets, load_lock, stage_store_guest


class StoreGuestPackagingTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        self.destination = self.root / 'destination'
        self.destination.mkdir()
        self.lock_path = self.root / 'lock.json'
        contents = {'Image': b'synthetic kernel SWIFT TEST', 'ingress.cpio': b'synthetic initramfs SWIFT TEST'}
        self.lock = dict(version=2, recipe='test-api-1',
                         files={name: hashlib.sha256(body).hexdigest() for name, body in contents.items()})
        self.notices = dict(version=1, recipe=self.lock['recipe'], files=dict(self.lock['files']),
                            components=[
                                dict(id=f'fixture-{index}', assets=[name], notice=f'Synthetic notice {index}',
                                     sources=[dict(url=f'https://example.invalid/source/{index}', sha256='a' * 64)])
                                for index, name in enumerate(contents)
                            ])
        for name, body in contents.items():
            (self.assets / name).write_bytes(body)
        self._pin_notices()

    def _pin_notices(self, raw=None):
        if raw is None:
            raw = json.dumps(self.notices).encode()
        (self.assets / NOTICES).write_bytes(raw)
        self.lock['notices'] = hashlib.sha256(raw).hexdigest()
        self.lock_path.write_text(json.dumps(self.lock))

    def test_copy_exact_pinned_resources_only(self):
        (self.assets / 'not-packaged').write_bytes(b'extra')
        copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        self.assertEqual(set(path.name for path in self.destination.iterdir()), {'Image', 'ingress.cpio', NOTICES})
        for name in ('Image', 'ingress.cpio', NOTICES):
            self.assertEqual((self.destination / name).read_bytes(), (self.assets / name).read_bytes())

    def test_reject_changed_resource_and_symlink(self):
        (self.assets / 'Image').write_bytes(b'different')
        with self.assertRaisesRegex(ValueError, 'pinned SHA-256'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        (self.destination / 'Image').unlink()
        (self.assets / 'Image').unlink()
        (self.assets / 'Image').symlink_to(self.assets / 'ingress.cpio')
        with self.assertRaises(OSError):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)

    def test_reject_absent_unpinned_and_symlinked_notices_before_copy(self):
        notice = self.assets / NOTICES
        notice.write_bytes(b'unpinned')
        with self.assertRaisesRegex(ValueError, 'notices do not match pinned SHA-256'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        notice.unlink()
        with self.assertRaises(FileNotFoundError):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        notice.symlink_to(self.assets / 'Image')
        with self.assertRaises(OSError):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        self.assertFalse(list(self.destination.iterdir()))

    def test_reject_symlink_asset_directory(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.assets, target_is_directory=True)
        with self.assertRaises(OSError):
            copy_pinned_assets(alias, load_lock(self.lock_path), self.destination)
        self.assertFalse(list(self.destination.iterdir()))

    def test_asset_opens_keep_the_original_directory_after_path_swap(self):
        original = self.root / 'moved-assets'
        replacement = self.root / 'replacement'
        replacement.mkdir()
        (replacement / 'Image').write_bytes(b'wrong bytes')
        lock = load_lock(self.lock_path)

        def swap_before_first_open(name, maximum, *, dir_fd=None):
            if name == NOTICES:
                self.assets.rename(original)
                self.assets.symlink_to(replacement, target_is_directory=True)
            self.assertIsNotNone(dir_fd)
            return _checked_file(name, maximum, dir_fd=dir_fd)

        with mock.patch('store_guest_packaging._checked_file', side_effect=swap_before_first_open):
            copy_pinned_assets(self.assets, lock, self.destination)
        for name in ('Image', 'ingress.cpio', NOTICES):
            self.assertEqual((self.destination / name).read_bytes(), (original / name).read_bytes())

    def test_reject_invisible_and_non_utf8_inline_notices(self):
        component = self.notices['components'][0]
        for notice, reason in (
            ('\u200b\ufeff\u2060', 'missing inline notice'),
            ('\x00\x1b\n\t', 'missing inline notice'),
            ('Synthetic notice \ud800', 'invalid UTF-8 notice'),
        ):
            with self.subTest(notice=notice):
                component['notice'] = notice
                self._pin_notices()
                with self.assertRaisesRegex(ValueError, reason):
                    copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        self.assertFalse(list(self.destination.iterdir()))
        component['notice'] = '合成声明 \n Synthetic notice ©'
        self._pin_notices()
        copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)

    def test_reject_pinned_notice_for_other_recipe_or_other_asset_bytes(self):
        self.notices['recipe'] = 'other-test'
        self._pin_notices()
        with self.assertRaisesRegex(ValueError, 'not bound'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        self.notices['recipe'] = self.lock['recipe']
        self.notices['files']['Image'] = 'b' * 64
        self._pin_notices()
        with self.assertRaisesRegex(ValueError, 'not bound'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)

    def test_reject_missing_coverage_and_external_only_notices(self):
        components = self.notices['components']
        self.notices['components'] = components[:1]
        self._pin_notices()
        with self.assertRaisesRegex(ValueError, 'do not cover exactly'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        self.notices['components'] = components
        components[0]['notice'] = '  '
        self._pin_notices()
        with self.assertRaisesRegex(ValueError, 'missing inline notice'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        components[0]['notice'] = 'Synthetic notice'
        components[0]['assets'] = ['../Image', 'ingress.cpio']
        self._pin_notices()
        with self.assertRaisesRegex(ValueError, 'invalid Store guest notice asset references'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)

    def test_reject_missing_or_malformed_corresponding_source_references(self):
        component = self.notices['components'][0]
        component['sources'] = []
        self._pin_notices()
        with self.assertRaisesRegex(ValueError, 'missing corresponding-source'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)
        for source in (
            dict(url='file:///tmp/source', sha256='a' * 64),
            dict(url='https://user@example.invalid/source', sha256='a' * 64),
            dict(url='https://example.invalid/source?query=1', sha256='a' * 64),
            dict(url='https://example.invalid/source', sha256='1'),
        ):
            with self.subTest(source=source):
                component['sources'] = [source]
                self._pin_notices()
                with self.assertRaisesRegex(ValueError, 'corresponding-source'):
                    copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)

    def test_reject_duplicate_json_fields_even_when_pinned(self):
        self._pin_notices(b'{"version": 1, "version": 1}')
        with self.assertRaisesRegex(ValueError, 'duplicate key'):
            copy_pinned_assets(self.assets, load_lock(self.lock_path), self.destination)

    def test_stages_exact_notices_before_unchanged_signing_and_verification(self):
        resources = self.root / 'Resources'
        resources.mkdir()
        (resources / 'StoreGuest.lock.json').write_bytes(self.lock_path.read_bytes())
        (self.root / HELPER_NAME).write_bytes(b'inert helper')
        applicant = self.root / 'Keylane.app'
        expected_bundle = applicant / f'Contents/Helpers/{HELPER_NAME}.app'

        def record_sign(command, **kwargs):
            guest_resources = expected_bundle / 'Contents/Resources'
            self.assertEqual({path.name for path in guest_resources.iterdir()}, {'Image', 'ingress.cpio', NOTICES})
            self.assertEqual((guest_resources / NOTICES).read_bytes(), (self.assets / NOTICES).read_bytes())

        with mock.patch('store_guest_packaging.subprocess.run', side_effect=record_sign) as runner:
            self.assertEqual(stage_store_guest(applicant, self.root, self.assets, self.root / 'Keylane',
                                               'test-identity', ['test-option']), expected_bundle)
            self.assertEqual(runner.call_args_list, [
                mock.call(['codesign', '--force', '--sign', 'test-identity', 'test-option',
                           '--entitlements', str(resources / 'KeylaneStoreGuest.entitlements'), str(expected_bundle)], check=True),
                mock.call(['codesign', '--verify', '--deep', '--strict', str(expected_bundle)], check=True),
            ])

    def test_default_package_still_skips_the_guest(self):
        script = pathlib.Path(__file__).with_name('package.py').resolve()
        binary = self.root / 'InertKeylane'
        binary.write_bytes(b'inert app')
        output = self.root / 'InertKeylane.dmg'
        commands = []

        def record_command(command, **kwargs):
            commands.append(command[0])
            if command[0] == 'xcrun':
                pathlib.Path(command[command.index('--output-partial-info-plist') + 1]).write_bytes(plistlib.dumps({}))
            elif command[0] == 'hdiutil':
                app = pathlib.Path(command[command.index('-srcfolder') + 1]) / 'Keylane.app'
                self.assertFalse((app / 'Contents/Helpers').exists())
                pathlib.Path(command[-1]).write_bytes(b'inert disk image')

        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(sys, 'argv', [str(script), str(binary), str(output)]), \
                mock.patch('signing.signing_identity', return_value='-'), mock.patch.object(subprocess, 'run', side_effect=record_command), \
                mock.patch('app_intents.extract_metadata') as extract_metadata, \
                mock.patch('store_guest_packaging.stage_store_guest') as stage, mock.patch('builtins.print'):
            runpy.run_path(str(script), run_name='__main__')
        extract_metadata.assert_called_once()
        stage.assert_not_called()
        self.assertEqual(commands, ['xcrun', 'codesign', 'codesign', 'hdiutil'])
        self.assertEqual(output.read_bytes(), b'inert disk image')

    def test_no_lock_or_adhoc_signature(self):
        applicant = self.root / 'Keylane.app'
        with self.assertRaisesRegex(ValueError, 'no ad-hoc'):
            stage_store_guest(applicant, self.root, self.assets, self.root / 'Keylane', '-', [])
        with self.assertRaisesRegex(ValueError, 'reviewed .* absent'):
            stage_store_guest(applicant, self.root, self.assets, self.root / 'Keylane', 'test-identity', [])
        self.assertFalse(applicant.exists())

    def test_wrong_types_and_wrong_entry_rejected(self):
        for patch in ({'version': True}, {'version': 1}, {'recipe': '../package'},
                      {'files': {'host': 'a' * 64}}, {'notices': 'invalid'}):
            self.lock_path.write_text(json.dumps({**self.lock, **patch}))
            with self.assertRaises(ValueError):
                load_lock(self.lock_path)

if __name__ == '__main__':
    unittest.main()
