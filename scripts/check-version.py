#!/usr/bin/env python3
"""Validate metadata, ordinary main syncs, and explicit stable releases."""
import argparse
import ast
import json
import os
import re
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
    parser.add_argument('--sync-policy', action='store_true')
    args = parser.parse_args()
    current = load_version()
    if args.require_bump:
        if not args.base_ref:
            raise ValueError('--require-bump needs --base-ref')
        ensure_increase(current, previous_version(args.base_ref))
    if args.sync_policy and os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        pr = event['pull_request']
        if pr['base']['ref'] == 'main':
            if pr['head']['ref'] != 'dev' or pr['head']['repo']['full_name'] != os.environ['GITHUB_REPOSITORY']:
                raise ValueError('main accepts PRs from this repository dev branch only')
    if args.release_policy:
        if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch' or os.environ.get('GITHUB_REF') != 'refs/heads/main':
            raise ValueError('release requires an explicit workflow_dispatch on main')
        sha = os.environ.get('GITHUB_SHA', '')
        if not re.fullmatch(r'[0-9a-f]{40}', sha) or git('rev-parse', 'HEAD') != sha:
            raise ValueError('release checkout must match the fixed workflow commit')
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        if event.get('inputs', {}).get('target_sha') != sha:
            raise ValueError('target_sha must equal the main workflow commit')
        tag = 'v' + current['version']
        stable = []
        for existing in git('tag', '--list', 'v*').splitlines():
            if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)(?:\.[1-9][0-9]*)?)?', existing):
                continue
            commit = git('rev-parse', f'{existing}^{{commit}}')
            if existing == tag:
                if commit != sha:
                    raise ValueError(tag + ' already belongs to a different release')
                continue  # immutable completed/draft retry of the exact commit
            previous = previous_version(existing)
            if current['build'] <= previous['build']:
                raise ValueError('release build must exceed every previous public build')
            if '-' not in existing:
                stable.append(previous)
        for previous in stable:
            ensure_increase(current, previous)
    print(f"Version {current['version']}, build {current['build']}: OK")
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with open(output, 'a') as file:
            file.write(f"version={current['version']}\ntag=v{current['version']}\n")


if __name__ == '__main__':
    main()
