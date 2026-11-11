import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from versioning import ensure_increase, parse_version

spec = importlib.util.spec_from_file_location('check_version', ROOT / 'scripts/check-version.py')
check_version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_version)


class VersionTests(unittest.TestCase):
    def test_rejects_invalid_metadata(self):
        for version, build in [('v1.0.0', 1), ('01.0.0', 1), ('1.0', 1), ('1.0.0-beta', 1), ('1.0.0', True), ('1.0.0', 0), ('1.0.0', '22')]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                parse_version(json.dumps({'version': version, 'build': build}))

    def test_numeric_version_comparison_and_build_must_increase(self):
        old = {'version': '0.9.9', 'build': 22}
        ensure_increase({'version': '0.10.0', 'build': 23}, old)
        for current in [{'version': '0.9.9', 'build': 23}, {'version': '0.9.8', 'build': 23}, {'version': '1.0.0', 'build': 22}]:
            with self.subTest(current=current), self.assertRaises(ValueError):
                ensure_increase(current, old)

    def test_adoption_reads_existing_main_metadata(self):
        # This commit predates version.json. Keep the initial migration reproducible.
        previous = check_version.previous_version('877ca22df5cea229b41256fdc70e79cd1780a766')
        self.assertEqual(previous, {'version': '0.10.0', 'build': 22})

class ReleasePolicyTests(unittest.TestCase):
    def run_policy(self, *, branch='dev', repo='Acckion/Keylane', title='release: v0.10.0', event_name='pull_request', tag_commit=None):
        import os
        import subprocess
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / 'event.json'
            event.write_text(json.dumps({'pull_request': {'head': {'ref': branch, 'repo': {'full_name': repo}}, 'title': title}}))
            environment = {'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': event_name, 'GITHUB_REPOSITORY': 'Acckion/Keylane', 'GITHUB_REF': 'refs/heads/main'}
            tag_result = subprocess.CompletedProcess([], 0 if tag_commit else 1, stdout=(tag_commit or ''), stderr='')
            with patch.dict(os.environ, environment, clear=True), patch.object(sys, 'argv', ['check-version.py', '--release-policy']), patch.object(check_version.subprocess, 'run', return_value=tag_result), patch.object(check_version, 'git', return_value='current-commit'), patch.object(check_version, 'load_version', return_value={'version': '0.10.0', 'build': 22}):
                check_version.main()

    def test_main_accepts_only_own_dev_and_matching_version_title(self):
        self.run_policy()
        for options in [{'branch': 'feat/example'}, {'repo': 'someone/Keylane'}, {'title': 'release: v0.10.1'}]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.run_policy(**options)

    def test_existing_tag_cannot_be_reused_by_release_pr(self):
        with self.assertRaises(ValueError):
            self.run_policy(tag_commit='current-commit')

    def test_completed_main_retry_requires_same_commit(self):
        self.run_policy(event_name='push', tag_commit='current-commit')
        with self.assertRaises(ValueError):
            self.run_policy(event_name='push', tag_commit='different-commit')


if __name__ == '__main__':
    unittest.main()
