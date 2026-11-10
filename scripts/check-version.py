#!/usr/bin/env python3
"""Validate metadata and main-release policy before building or tagging."""
import argparse
import ast
import json
import os
import subprocess
from pathlib import Path
from versioning import ROOT, ensure_increase, load_version, parse_version


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def previous_version(ref):
    # One-time adoption: the old main stored version metadata in package.py.
    if subprocess.run(['git', 'cat-file', '-e', f'{ref}:version.json'], cwd=ROOT, capture_output=True).returncode == 0:
        return parse_version(git('show', f'{ref}:version.json'))
    tree = ast.parse(git('show', f'{ref}:scripts/package.py'))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            values = {kw.arg: kw.value.value for kw in node.keywords if isinstance(kw.value, ast.Constant)}
            if 'CFBundleShortVersionString' in values and 'CFBundleVersion' in values:
                return parse_version(json.dumps({'version': values['CFBundleShortVersionString'], 'build': int(values['CFBundleVersion'])}))
    raise ValueError('cannot determine base version; do not bypass release comparison')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-ref')
    parser.add_argument('--require-bump', action='store_true')
    parser.add_argument('--release-policy', action='store_true')
    args = parser.parse_args()
    current = load_version()
    if args.require_bump:
        if not args.base_ref:
            raise ValueError('--require-bump needs --base-ref')
        ensure_increase(current, previous_version(args.base_ref))
    if args.release_policy:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        tag = 'v' + current['version']
        if os.environ['GITHUB_EVENT_NAME'] == 'pull_request':
            pr = event['pull_request']
            if pr['head']['ref'] != 'dev' or pr['head']['repo']['full_name'] != os.environ['GITHUB_REPOSITORY']:
                raise ValueError('main accepts release PRs from this repository dev branch only')
            if pr['title'] != 'release: ' + tag:
                raise ValueError('release PR title must be release: ' + tag)
        elif os.environ['GITHUB_REF'] != 'refs/heads/main':
            raise ValueError('release policy must run on main')
        ref = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}'], cwd=ROOT, text=True, capture_output=True)
        if ref.returncode == 0 and (os.environ['GITHUB_EVENT_NAME'] == 'pull_request' or ref.stdout.strip() != git('rev-parse', 'HEAD')):
            raise ValueError(tag + ' already belongs to a different release')
    print(f"Version {current['version']}, build {current['build']}: OK")
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with open(output, 'a') as file:
            file.write(f"version={current['version']}\ntag=v{current['version']}\n")


if __name__ == '__main__':
    main()
