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
    SHA = 'a' * 40

    def run_policy(self, *, policy='release', branch='dev', repo='Acckion/Keylane', base='main', event_name='workflow_dispatch', ref='refs/heads/main', target=None, head=None, tags=None, previous=None, current=None):
        import os
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / 'event.json'
            event.write_text(json.dumps({'inputs': {'target_sha': self.SHA if target is None else target}, 'pull_request': {'base': {'ref': base}, 'head': {'ref': branch, 'repo': {'full_name': repo}}, 'title': 'chore: sync stable snapshot'}}))
            environment = {'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': event_name, 'GITHUB_REPOSITORY': 'Acckion/Keylane', 'GITHUB_REF': ref, 'GITHUB_SHA': self.SHA}
            def git(*args):
                if args[0] == 'tag':
                    return '\n'.join(tags or {})
                if args[1] == 'HEAD':
                    return head or self.SHA
                return tags[args[1].removesuffix('^{commit}')]
            with patch.dict(os.environ, environment, clear=True), patch.object(sys, 'argv', ['check-version.py', '--' + policy + '-policy']), patch.object(check_version, 'git', side_effect=git), patch.object(check_version, 'previous_version', return_value=previous or {'version': '1.0.0', 'build': 22}), patch.object(check_version, 'load_version', return_value=current or {'version': '1.1.0', 'build': 23}):
                check_version.main()

    def test_sync_accepts_own_dev_without_release_title_or_bump(self):
        self.run_policy(policy='sync', event_name='pull_request', current={'version': '1.0.0', 'build': 22})
        for options in [{'branch': 'feat/example'}, {'repo': 'someone/Keylane'}]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.run_policy(policy='sync', event_name='pull_request', **options)
        self.run_policy(policy='sync', event_name='pull_request', base='dev', branch='feat/example')

    def test_only_explicit_main_dispatch_can_release(self):
        self.run_policy()
        for options in [{'event_name': 'push'}, {'event_name': 'pull_request'}, {'event_name': 'workflow_run'}, {'ref': 'refs/heads/dev'}, {'target': 'b' * 40}, {'head': 'b' * 40}]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.run_policy(**options)

    def test_existing_tag_is_immutable_but_same_commit_retry_allowed(self):
        self.run_policy(tags={'v1.1.0': self.SHA})
        with self.assertRaises(ValueError):
            self.run_policy(tags={'v1.1.0': 'b' * 40})

    def test_versions_and_builds_compare_to_public_tags_not_parent_sync(self):
        self.run_policy(tags={'v1.0.0': 'b' * 40})
        for options in [dict(current={'version': '1.0.0', 'build': 23}), dict(current={'version': '1.1.0', 'build': 22})]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.run_policy(tags={'v1.0.0': 'b' * 40}, **options)
        for tag in ['v1.1.0-beta.1', 'v1.1.0-alpha']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.run_policy(tags={tag: 'b' * 40}, previous={'version': '1.1.0', 'build': 23})


if __name__ == '__main__':
    unittest.main()
