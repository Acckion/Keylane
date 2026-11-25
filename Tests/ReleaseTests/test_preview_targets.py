"""No credentials: integrated-push-only signing and workflow contracts."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('preview', ROOT / 'scripts/check-preview-target.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)
SHA = 'a' * 40


class PreviewTargetTests(unittest.TestCase):
    def test_only_integrated_pushes_are_allowed(self):
        for ref in ['refs/heads/dev', 'refs/heads/main']:
            preview.validate('push', ref, SHA)
        for ref in ['refs/heads/feature', 'refs/tags/main', 'refs/pull/152/merge']:
            with self.assertRaises(ValueError):
                preview.validate('push', ref, SHA)

    def test_every_pr_and_privileged_or_manual_event_is_rejected(self):
        # Source repository and actor cannot grant any exception, including same-repo PRs.
        for event in ['pull_request', 'pull_request_target', 'workflow_run', 'workflow_dispatch', 'repository_dispatch']:
            for ref in ['refs/heads/dev', 'refs/heads/main', 'refs/pull/152/merge']:
                with self.subTest(event=event, ref=ref), self.assertRaises(ValueError):
                    preview.validate(event, ref, SHA)

    def test_requires_full_sha(self):
        for sha in ['', 'main', 'a' * 39, 'g' * 40]:
            with self.assertRaises(ValueError):
                preview.validate('push', 'refs/heads/dev', sha)

    def test_cli_checks_checkout_and_fails_before_commands_for_pr(self):
        env = {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/dev', 'GITHUB_SHA': SHA}
        with patch.dict(os.environ, env, clear=True), patch.object(preview.subprocess, 'check_output', return_value=SHA):
            preview.main()
        for reply in ['b' * 40, subprocess.CalledProcessError(1, 'git')]:
            with patch.dict(os.environ, env, clear=True), patch.object(preview.subprocess, 'check_output', side_effect=[reply]):
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    preview.main()
        with patch.dict(os.environ, {**env, 'GITHUB_EVENT_NAME': 'pull_request'}, clear=True), patch.object(preview.subprocess, 'check_output') as run:
            with self.assertRaises(ValueError):
                preview.main()
            run.assert_not_called()

    def test_workflow_never_signs_or_packages_a_pr(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        checks, signing = ci.split('  sign-preview-auto:', 1)
        self.assertIn('  pull_request:', checks)
        pr_trigger = checks.split('  pull_request:', 1)[1].split('  push:', 1)[0]
        self.assertEqual(pr_trigger.strip(), 'branches: [dev, main]', 'Retargeted PRs use the dev/main Checks gate')
        self.assertIn('name: Checks', checks)
        for forbidden in ['secrets.', 'environment:', 'scripts/package.sh', 'upload-artifact@']:
            self.assertNotIn(forbidden, checks)
        self.assertNotIn('sign-preview-pr', ci)
        self.assertNotIn('preview-signing-pr', ci)
        self.assertIn("github.event_name == 'push'", signing)
        self.assertNotIn('workflow_dispatch', signing)
        self.assertIn("github.ref == 'refs/heads/dev' || github.ref == 'refs/heads/main'", signing)
        self.assertIn('environment: preview-signing-auto', signing)
        self.assertIn('ref: ${{ github.sha }}', signing)
        self.assertLess(signing.index('check-preview-target.py'), signing.index('secrets.KEYLANE_PREVIEW_P12'))
        self.assertIn('persist-credentials: false', signing)
        for forbidden in ['pull_request_target:', 'workflow_run:', 'contents: write']:
            self.assertNotIn(forbidden, ci)
