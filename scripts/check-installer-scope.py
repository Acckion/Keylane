#!/usr/bin/env python3
"""Select installer validation for PR/push changes; fail closed on unknown bases."""
import json
import os
import subprocess
from pathlib import Path


def requires_installer(paths):
    prefixes = ('.github/workflows/', 'scripts/', 'Resources/', '.swiftpm/')
    files = {'Package.swift', 'Package.resolved', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'version.json'}
    return any(path in files or path.startswith(prefixes) for path in paths)


def main():
    event_name = os.environ['GITHUB_EVENT_NAME']
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    required = True
    if event_name == 'workflow_dispatch':
        required = os.environ.get('VALIDATE_INSTALLER') == 'true'
    else:
        base = event['pull_request']['base']['sha'] if event_name == 'pull_request' else event.get('before', '')
        if base and set(base) != {'0'}:
            result = subprocess.run(['git', 'diff', '--name-only', '--no-renames', '-z', base, 'HEAD'], capture_output=True, text=True)
            if result.returncode == 0:
                required = requires_installer(result.stdout.strip('\0').split('\0'))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'required={str(required).lower()}\n')
    print(f'Installer validation required: {required}')


if __name__ == '__main__':
    main()
