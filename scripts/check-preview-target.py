#!/usr/bin/env python3
"""Defence-in-depth target check; environment protection is the security boundary."""
import json
import os
import re
import subprocess
from pathlib import Path


def validate(event_name, ref, repository, actor, sha, event, current_pr=None, run_attempt=1):
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Preview requires a fixed commit SHA')
    if actor == 'dependabot[bot]':
        raise ValueError('Dependabot runs cannot use preview signing')
    if event_name in {'push', 'workflow_dispatch'}:
        if ref not in {'refs/heads/dev', 'refs/heads/main'}:
            raise ValueError('Automatic previews require dev or main')
        return 'auto'
    if event_name != 'pull_request':
        raise ValueError('Unsupported preview event')
    if run_attempt != 1:
        raise ValueError('PR signing reruns require a new run and approval')
    pr = event['pull_request']
    if (pr['head']['repo']['full_name'] != repository or
            pr['base']['repo']['full_name'] != repository or
            pr['base']['ref'] not in {'dev', 'main'} or
            pr['user']['login'] == 'dependabot[bot]'):
        raise ValueError('Only non-Dependabot same-repository PRs may request approval')
    if ref != f"refs/pull/{event['number']}/merge":
        raise ValueError('PR preview must use its merge ref')
    if not current_pr or current_pr.get('state') != 'open':
        raise ValueError('PR must still be open after approval')
    if (current_pr['head']['repo']['full_name'] != repository or
            current_pr['base']['repo']['full_name'] != repository or
            current_pr['base']['ref'] != pr['base']['ref'] or
            current_pr['head']['sha'] != pr['head']['sha'] or
            current_pr['base']['sha'] != pr['base']['sha'] or
            current_pr.get('merge_commit_sha') != sha):
        raise ValueError('PR changed or merge snapshot is stale; start a new run and approval')
    return 'pr'


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    repository = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository')
    event_name = os.environ['GITHUB_EVENT_NAME']
    current = None
    if event_name == 'pull_request':
        number = event['number']
        if type(number) is not int or number <= 0:
            raise ValueError('Invalid PR number')
        # Read metadata only. No privileged event, artifact, cache or remote script.
        current = json.loads(subprocess.check_output(
            ['gh', 'api', f'repos/{repository}/pulls/{number}'], text=True))
    mode = validate(event_name, os.environ['GITHUB_REF'], repository,
                    os.environ['GITHUB_ACTOR'], os.environ['GITHUB_SHA'], event, current,
                    int(os.environ['GITHUB_RUN_ATTEMPT']))
    expected_mode = os.environ['PREVIEW_MODE']
    if mode != expected_mode:
        raise ValueError('Preview environment does not match the event')
    checkout = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if checkout != os.environ['GITHUB_SHA']:
        raise ValueError('Checkout does not match the approved snapshot')
    print(f"Preview target verified: {mode} {checkout}")


if __name__ == '__main__':
    main()
