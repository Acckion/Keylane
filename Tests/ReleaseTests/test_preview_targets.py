"""No real credentials/API calls: target policy and checked-in workflow contracts."""
import copy
import importlib.util
import json
import os
import subprocess
import tempfile
from unittest.mock import patch
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('preview', ROOT / 'scripts/check-preview-target.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)
REPO = 'Acckion/Keylane'
SHA = 'a' * 40


def fixture():
    pr = {'state': 'open', 'user': {'login': 'maintainer'},
          'head': {'repo': {'full_name': REPO}, 'sha': 'b' * 40},
          'base': {'repo': {'full_name': REPO}, 'ref': 'dev', 'sha': 'c' * 40},
          'merge_commit_sha': SHA}
    return {'number': 152, 'pull_request': pr}, copy.deepcopy(pr)


class PreviewTargetTests(unittest.TestCase):
    def check(self, event='pull_request', ref='refs/pull/152/merge', actor='maintainer', payload=None, current=None):
        original, live = fixture()
        return preview.validate(event, ref, REPO, actor, SHA,
                                original if payload is None else payload,
                                live if current is None else current)

    def test_integrated_push_and_manual_allowed_only_on_dev_main(self):
        for event in ['push', 'workflow_dispatch']:
            for ref in ['refs/heads/dev', 'refs/heads/main']:
                self.assertEqual(self.check(event=event, ref=ref), 'auto')
            for ref in ['refs/heads/feature', 'refs/tags/main', 'refs/pull/152/merge']:
                with self.assertRaises(ValueError):
                    self.check(event=event, ref=ref)

    def test_same_repo_pr_uses_reviewed_merge_snapshot(self):
        self.assertEqual(self.check(), 'pr')
        for field in ['head', 'base']:
            event, current = fixture()
            current[field]['sha'] = 'd' * 40
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.check(payload=event, current=current)
        event, current = fixture()
        current['merge_commit_sha'] = 'd' * 40
        with self.assertRaises(ValueError):
            self.check(payload=event, current=current)

    def test_closed_or_retargeted_pr_rejected(self):
        event, current = fixture()
        current['state'] = 'closed'
        with self.assertRaises(ValueError):
            self.check(payload=event, current=current)
        event, current = fixture()
        current['base']['ref'] = 'main'
        with self.assertRaises(ValueError):
            self.check(payload=event, current=current)

    def test_fork_and_dependabot_cannot_select_signing(self):
        event, current = fixture()
        event['pull_request']['head']['repo']['full_name'] = 'untrusted/Keylane'
        with self.assertRaises(ValueError):
            self.check(payload=event, current=current)
        with self.assertRaises(ValueError):
            self.check(actor='dependabot[bot]')
        event, current = fixture()
        event['pull_request']['user']['login'] = 'dependabot[bot]'
        with self.assertRaises(ValueError):
            self.check(payload=event, current=current)

    def test_privileged_events_and_wrong_ref_rejected(self):
        for event in ['pull_request_target', 'workflow_run', 'repository_dispatch']:
            with self.assertRaises(ValueError):
                self.check(event=event, ref='refs/heads/main')
        with self.assertRaises(ValueError):
            self.check(ref='refs/heads/main')

    def test_pr_reruns_require_a_new_approval_run(self):
        event, current = fixture()
        with self.assertRaisesRegex(ValueError, 'new run'):
            preview.validate('pull_request', 'refs/pull/152/merge', REPO,
                             'maintainer', SHA, event, current, run_attempt=2)
        self.assertEqual(preview.validate('push', 'refs/heads/dev', REPO,
                                         'maintainer', SHA, {}, run_attempt=2), 'auto')

    def test_main_fails_closed_on_api_checkout_or_mode_errors(self):
        event, current = fixture()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'event.json'
            path.write_text(json.dumps(event))
            env = {'GITHUB_EVENT_PATH': str(path), 'GITHUB_REPOSITORY': REPO,
                   'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/pull/152/merge',
                   'GITHUB_ACTOR': 'maintainer', 'GITHUB_SHA': SHA,
                   'GITHUB_RUN_ATTEMPT': '1', 'PREVIEW_MODE': 'pr'}
            for responses, mode, error in [
                ([subprocess.CalledProcessError(1, 'gh')], 'pr', subprocess.CalledProcessError),
                ([json.dumps(current), 'd' * 40], 'pr', ValueError),
                ([json.dumps(current)], 'auto', ValueError),
            ]:
                with self.subTest(mode=mode, responses=responses), patch.dict(os.environ, {**env, 'PREVIEW_MODE': mode}, clear=True), patch.object(preview.subprocess, 'check_output', side_effect=responses):
                    with self.assertRaises(error):
                        preview.main()
            with patch.dict(os.environ, env, clear=True), patch.object(preview.subprocess, 'check_output', side_effect=[json.dumps(current), SHA]):
                preview.main()

    def test_workflow_preserves_two_distinct_security_boundaries(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        checks, rest = ci.split('  sign-preview-auto:', 1)
        auto, pr = rest.split('  sign-preview-pr:', 1)
        self.assertNotIn('secrets.', checks)
        self.assertIn('environment: preview-signing-auto', auto)
        self.assertIn("github.event_name == 'push' || github.event_name == 'workflow_dispatch'", auto)
        self.assertIn('name: preview-signing-pr', pr)
        self.assertIn("github.event_name == 'pull_request'", pr)
        self.assertIn('github.event.pull_request.head.sha', pr)
        for job in [auto, pr]:
            self.assertLess(job.index('check-preview-target.py'), job.index('secrets.KEYLANE_PREVIEW_P12'))
            self.assertIn('ref: ${{ github.sha }}', job)
            self.assertIn('persist-credentials: false', job)
        for trigger in ['pull_request_target:', 'workflow_run:']:
            self.assertNotIn(trigger, ci)
