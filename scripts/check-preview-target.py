#!/usr/bin/env python3
"""Push-only preview guard. Server-side environment ref policy is also required."""
import os
import re
import subprocess


def validate(event_name, ref, sha):
    if event_name != 'push':
        raise ValueError('Preview signing requires an integrated branch push')
    if ref not in {'refs/heads/dev', 'refs/heads/main'}:
        raise ValueError('Preview signing requires dev or main')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Preview requires a fixed commit SHA')


def main():
    sha = os.environ['GITHUB_SHA']
    validate(os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF'], sha)
    checkout = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if checkout != sha:
        raise ValueError('Checkout does not match the integrated snapshot')
    print(f'Preview target verified: {sha}')


if __name__ == '__main__':
    main()
