import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import extension_builder as builder


class ExtensionBuilderPolicyTests(unittest.TestCase):
    def test_nested_timestamp_policy_precedes_recipe_hashes(self):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w:gz') as package:
            body = b'synthetic-compiler-not-executed'
            entry = tarfile.TarInfo('package/bin/esbuild'); entry.size = len(body)
            package.addfile(entry, io.BytesIO(body))
        for distribution in [False, True]:
            with self.subTest(distribution=distribution), tempfile.TemporaryDirectory(prefix='keylane-sign-policy-') as directory:
                root = Path(directory); helper = root/'helper'; helper.write_bytes(b'synthetic-helper-not-executed')
                app = root/'App.app'
                calls = []
                def sign(arguments, **_):
                    if '--force' in arguments:
                        calls.append(arguments)
                        target = Path(arguments[-1])
                        binary = target/'Contents/MacOS/keylane-extension-build' if target.is_dir() else target
                        binary.write_bytes(binary.read_bytes()+b'signature-control')
                    return SimpleNamespace(returncode=0)
                with patch.object(builder, 'archive_bytes', return_value=archive.getvalue()), patch.object(builder.subprocess, 'run', side_effect=sign):
                    builder.package_builder(app,helper,'synthetic-identity',team='TESTTEAM01',distribution=distribution)
                self.assertEqual(len(calls),2)
                for arguments in calls:
                    self.assertIn('--timestamp' if distribution else '--timestamp=none',arguments)
                    self.assertNotIn('--timestamp=none' if distribution else '--timestamp',arguments)
                profile = json.loads((app/'Contents/Resources/ExtensionBuild.json').read_text())
                self.assertEqual(profile['storage'],'data-protection-keychain-v2')
                for key,path in [('helperSHA256',app/builder.HELPER/'Contents/MacOS/keylane-extension-build'),
                                 ('compilerSHA256',app/builder.HELPER/'Contents/MacOS/esbuild')]:
                    self.assertEqual(profile['recipe'][key],hashlib.sha256(path.read_bytes()).hexdigest())

    def test_certificate_free_isolation_omits_builder_without_runtime_fallback(self):
        self.assertFalse(builder.builder_enabled('arm64','-',False))
        self.assertFalse(builder.builder_enabled('x86_64','synthetic-identity',False))
        self.assertTrue(builder.builder_enabled('arm64','synthetic-identity',False))
        self.assertTrue(builder.builder_enabled('arm64','synthetic-identity',True))
        with self.assertRaises(ValueError):builder.builder_enabled('arm64','-',True)

    def test_adhoc_inventory_rejects_partial_or_enabled_build_composition(self):
        with tempfile.TemporaryDirectory(prefix='keylane-unsigned-policy-') as directory:
            app = Path(directory)/'App.app'
            with patch.object(builder.subprocess,'check_output',return_value='Signature=adhoc\n'):
                self.assertEqual(builder.verify_build_composition(app,'arm64'),set())
                with self.assertRaises(ValueError):builder.verify_build_composition(app,'arm64',distribution=True)
                profile = app/'Contents/Resources/ExtensionBuild.json';profile.parent.mkdir(parents=True);profile.write_text('{}')
                with self.assertRaises(ValueError):builder.verify_build_composition(app,'arm64')
            with patch.object(builder.subprocess,'check_output',return_value='Authority=Apple Development: synthetic\n'), patch.object(builder,'verify_builder',return_value={'verified'}) as verify:
                self.assertEqual(builder.verify_build_composition(app,'arm64'),{'verified'})
                verify.assert_called_once_with(app,distribution=False)

    def test_distribution_timestamp_check_rejects_untimestamped_code(self):
        with patch.object(builder.subprocess,'check_output',return_value='Signed Time=synthetic\n'):
            with self.assertRaises(ValueError):builder.require_timestamp(Path('not-executed'))
        with patch.object(builder.subprocess,'check_output',return_value='Timestamp=synthetic-secure-time\n'):
            builder.require_timestamp(Path('not-executed'))

    def test_legacy_runtime_requires_explicit_preview_and_rejects_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)/'App.app'
            runner = Path(directory)/'runner'
            runner.write_bytes(b'synthetic')
            for legacy, expected in [(False, builder.PROTECTED_STORAGE), (True, builder.LEGACY_PREVIEW_STORAGE)]:
                app_path = app.with_name(f'{legacy}.app')
                config_path = app_path/'Contents/Resources/ExtensionBuild.json'
                config_path.parent.mkdir(parents=True)
                config_path.write_text(json.dumps({'mode': 'build-only', 'storage': builder.PROTECTED_STORAGE}))
                with patch.object(builder, 'team_for', return_value='TESTTEAM01'), patch.object(builder.subprocess, 'run'):
                    builder.package_runtime(app_path, runner, 'synthetic-identity', legacy_preview=legacy)
                config = json.loads(config_path.read_text())
                self.assertEqual(config['storage'], expected)
                self.assertEqual(config['mode'], 'restricted-no-view')
                self.assertEqual(config['runHelperSHA256'], hashlib.sha256(runner.read_bytes()).hexdigest())
            with self.assertRaisesRegex(ValueError, 'cannot be used for Developer ID'):
                builder.package_runtime(app, runner, 'synthetic-identity', distribution=True, legacy_preview=True)
