"""Exercise event selection and release entry guards without release credentials."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scope', ROOT / 'scripts/check-installer-scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class InstallerTests(unittest.TestCase):
    def run_scope(self, event_name, paths='', before='a' * 40, manual='false', diff_code=0):
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / 'event.json'
            output = Path(temporary) / 'output'
            event.write_text(json.dumps({'before': before, 'pull_request': {'base': {'sha': before}}}))
            environment = {'GITHUB_EVENT_NAME': event_name, 'GITHUB_EVENT_PATH': str(event), 'GITHUB_OUTPUT': str(output), 'VALIDATE_INSTALLER': manual}
            with patch.dict(os.environ, environment, clear=True), patch.object(scope.subprocess, 'run', return_value=subprocess.CompletedProcess([], diff_code, stdout=paths)):
                scope.main()
            return output.read_text().strip()

    def test_pr_and_push_scope_for_both_branch_targets(self):
        for event in ['pull_request', 'push']:
            self.assertEqual(self.run_scope(event, 'README.md\0Sources/Keylane/App.swift\0'), 'required=false')
            for path in ['scripts/package.py', '.github/workflows/release.yml', 'Resources/icon.png', 'Package.swift', 'version.json', 'LICENSE', 'THIRD_PARTY_NOTICES.md']:
                with self.subTest(event=event, path=path):
                    self.assertEqual(self.run_scope(event, path + '\0'), 'required=true')

    def test_unknown_base_fails_closed_and_manual_can_request_package(self):
        self.assertEqual(self.run_scope('push', before='0' * 40), 'required=true')
        self.assertEqual(self.run_scope('push', diff_code=128), 'required=true')
        self.assertEqual(self.run_scope('workflow_dispatch'), 'required=false')
        self.assertEqual(self.run_scope('workflow_dispatch', manual='true'), 'required=true')

    def test_moving_package_script_out_of_scope_still_requires_package(self):
        import sys
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'scripts/package.py').write_text('fixture')
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
            sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
            (root / 'scripts/package.py').rename(root / 'notes.md')
            subprocess.run(['git', '-C', str(root), 'add', '-A'], check=True)
            event = root / 'event.json'
            event.write_text(json.dumps({'before': sha}))
            output = root / 'output'
            environment = {**os.environ, 'GITHUB_EVENT_NAME': 'push', 'GITHUB_EVENT_PATH': str(event), 'GITHUB_OUTPUT': str(output)}
            # Commit the rename to model a push rather than an unstaged tree.
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'move'], check=True)
            subprocess.run([sys.executable, str(ROOT / 'scripts/check-installer-scope.py')], cwd=root, env=environment, check=True, capture_output=True)
            self.assertEqual(output.read_text().strip(), 'required=true')


class ReleaseEntryTests(unittest.TestCase):
    def test_publish_script_rejects_automatic_events_before_writes(self):
        for event in ['push', 'pull_request', 'workflow_run']:
            result = subprocess.run(['bash', 'scripts/publish-release.sh'], cwd=ROOT, env={**os.environ, 'GITHUB_SHA': 'a' * 40, 'GH_REPO': 'Acckion/Keylane', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': event}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('requires workflow_dispatch', result.stderr)

    def test_ci_keeps_preview_secrets_out_of_checks(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        checks, preview = ci.split('  sign-preview:\n', 1)
        self.assertNotIn('secrets.', checks)
        self.assertIn("github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/dev' && inputs.sign_preview", preview)
        self.assertIn('environment: preview-signing', preview)
        self.assertIn('needs: checks', preview)
        for forbidden in ['contents: write', 'publish-release.sh', 'workflow_run', 'notarize-dmg']:
            self.assertNotIn(forbidden, ci)
        self.assertIn('name: Checks', ci)
        self.assertIn('check-version.py --sync-policy', ci)
        release = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertIn('  workflow_dispatch:', release)
        for forbidden in ['  push:', '  pull_request:', '  workflow_run:']:
            self.assertNotIn(forbidden, release)
        for required in ['ref: ${{ github.sha }}', 'verify-package.py --distribution', 'check-version.py --release-policy', 'needs: build', 'cancel-in-progress: false']:
            self.assertIn(required, release)

    def test_missing_release_secrets_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = {**os.environ, 'RUNNER_TEMP': temporary, 'GITHUB_ENV': temporary + '/env', 'GITHUB_OUTPUT': temporary + '/output', 'GITHUB_REF': 'refs/heads/main', **dict.fromkeys(['CERTIFICATE', 'CERTIFICATE_PASSWORD', 'APPLE_ID', 'APPLE_TEAM_ID', 'APPLE_APP_PASSWORD'], '')}
            result = subprocess.run(['bash', 'scripts/import-release-certificate.sh'], cwd=ROOT, env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Configure Developer ID', result.stderr)

class ArtifactGuardTests(unittest.TestCase):
    def test_commit_or_checksum_mismatch_prevents_github_write(self):
        import shutil
        for mismatch in ['commit', 'checksum']:
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'scripts').mkdir()
                (root / 'docs/releases').mkdir(parents=True)
                (root / 'dist').mkdir()
                for name in ['publish-release.sh', 'check-version.py', 'versioning.py', 'check-release-notes.py']:
                    shutil.copyfile(ROOT / 'scripts' / name, root / 'scripts' / name)
                (root / 'version.json').write_text('{"version":"1.1.0","build":23}')
                (root / 'docs/releases/v1.1.0.md').write_text('# Guard fixture\n## 修复\n- **CI**：固定制品\n## 验证\n- 合成验证\n## 兼容性与已知限制\n- 测试夹具\n')
                subprocess.run(['git', 'init', '-q', str(root)], check=True)
                subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
                subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
                sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
                event = root / 'event.json'
                event.write_text(json.dumps({'inputs': {'target_sha': sha}}))
                (root / 'dist/commit.txt').write_text('wrong' if mismatch == 'commit' else sha)
                (root / 'dist/Keylane-1.1.0-macos-arm64.dmg').write_text('synthetic image')
                (root / 'dist/Keylane-1.1.0-macos-arm64.dmg.sha256').write_text('0' * 64 + '  Keylane-1.1.0-macos-arm64.dmg\n')
                binaries = root / 'bin'
                binaries.mkdir()
                gh = binaries / 'gh'
                gh.write_text('#!/bin/sh\ntouch "$GH_CALLED"\nexit 99\n')
                gh.chmod(0o755)
                checksum = binaries / 'sha256sum'
                checksum.write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n')
                checksum.chmod(0o755)
                called = root / 'github-called'
                environment = {**os.environ, 'PATH': str(binaries) + os.pathsep + os.environ['PATH'], 'GH_CALLED': str(called), 'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': sha, 'GH_REPO': 'Acckion/Keylane'}
                result = subprocess.run(['bash', 'scripts/publish-release.sh'], cwd=root, env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Version 1.1.0, build 23: OK", result.stdout)
                if mismatch == "checksum":
                    self.assertIn("Release notes for v1.1.0: OK", result.stdout)
                    self.assertIn("FAILED", result.stdout)
                self.assertFalse(called.exists(), result.stdout + result.stderr)

class DraftRetryTests(unittest.TestCase):
    def run_draft_retry(self, target, remote_tag=None):
        """Run the actual publisher in a local fixture; all gh calls are simulated."""
        import hashlib
        import shutil
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for directory in ['scripts', 'docs/releases', 'dist', 'bin']:
                (root / directory).mkdir(parents=True)
            for name in ['publish-release.sh', 'check-version.py', 'versioning.py', 'check-release-notes.py']:
                shutil.copyfile(ROOT / 'scripts' / name, root / 'scripts' / name)
            (root / 'version.json').write_text('{"version":"1.1.0","build":23}')
            (root / 'docs/releases/v1.1.0.md').write_text('# Draft fixture\n## 修复\n- **CI**：固定制品\n## 验证\n- 合成验证\n## 兼容性与已知限制\n- 测试夹具\n')
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), 'add', 'scripts', 'docs', 'version.json'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
            sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
            (root / 'event.json').write_text(json.dumps({'inputs': {'target_sha': sha}}))
            (root / 'dist/commit.txt').write_text(sha)
            archive = 'Keylane-1.1.0-macos-arm64.dmg'
            data = b'synthetic test image'
            (root / 'dist' / archive).write_bytes(data)
            (root / 'dist' / (archive + '.sha256')).write_text(hashlib.sha256(data).hexdigest() + '  ' + archive + '\n')
            state = {'isDraft': True, 'assets': [], 'targetCommitish': sha if target == 'matching' else target}
            (root / 'draft.json').write_text(json.dumps(state))
            gh = root / 'bin/gh'
            gh.write_text('''#!/bin/sh
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$1 $2" in
  "api "*)
    test -n "$GH_REMOTE_SHA" || exit 1
    printf '%s\n' "$GH_REMOTE_SHA" ;;
  "release view") cat "$GH_DRAFT_STATE" ;;
  "release upload"|"release edit") exit 0 ;;
  *) exit 99 ;;
esac
''')
            gh.chmod(0o755)
            # Simulate existing remote tags without creating or modifying any tag.
            git = root / 'bin/git'
            git.write_text("""#!/bin/sh
case "$1 $2" in
  "fetch origin") exit 0 ;;
  "rev-parse v1.1.0^{commit}") printf '%s\\n' "$GH_REMOTE_SHA" ;;
  *) exec """ + shutil.which('git') + ' "$@" ;;\nesac\n')
            git.chmod(0o755)
            checksum = root / 'bin/sha256sum'
            checksum.write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n')
            checksum.chmod(0o755)
            environment = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'], 'GH_CALL_LOG': str(root / 'calls'), 'GH_REMOTE_SHA': sha if remote_tag == 'matching' else (remote_tag or ''), 'GH_DRAFT_STATE': str(root / 'draft.json'), 'GITHUB_EVENT_PATH': str(root / 'event.json'), 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': sha, 'GH_REPO': 'Acckion/Keylane'}
            result = subprocess.run(['bash', 'scripts/publish-release.sh'], cwd=root, env=environment, capture_output=True, text=True)
            return result, (root / 'calls').read_text()

    def test_untagged_draft_with_wrong_or_mutable_target_rejects_before_writes(self):
        for target in ['b' * 40, 'main', '', None]:
            with self.subTest(target=target):
                result, calls = self.run_draft_retry(target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Untagged draft targetCommitish must equal', result.stderr)
                self.assertIn('release view v1.1.0 --json isDraft,assets,targetCommitish', calls)
                for operation in ['release upload', 'release edit', 'release create']:
                    self.assertNotIn(operation, calls)

    def test_untagged_draft_with_exact_sha_can_retry_in_order(self):
        result, calls = self.run_draft_retry('matching')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(calls.index('release view'), calls.index('release upload'))
        self.assertLess(calls.index('release upload'), calls.index('release edit'))
        self.assertNotIn('release create', calls)
        self.assertEqual(calls.count('release upload'), 1)
        self.assertEqual(calls.count('release edit'), 1)

    def test_existing_matching_tag_controls_draft_retry_target(self):
        result, calls = self.run_draft_retry('main', remote_tag='matching')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('release upload', calls)
        self.assertIn('release edit', calls)

    def test_existing_mismatched_tag_rejects_before_draft_writes(self):
        result, calls = self.run_draft_retry('matching', remote_tag='b' * 40)
        self.assertNotEqual(result.returncode, 0)
        for operation in ['release view', 'release upload', 'release edit', 'release create']:
            self.assertNotIn(operation, calls)
