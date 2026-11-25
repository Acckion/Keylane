#!/usr/bin/env python3
"""Exercise the signed M2 driver with fixed first-party inputs and no install."""
import argparse
import csv
import fcntl
import hashlib
import io
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import time

from extension_builder import archive_bytes

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('broker', ROOT/'scripts/verify-macos-broker-m0.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)


def verify_batch_01(host, task, compiler_archive, api_archive):
    fixture = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM2'
    with (ROOT / 'docs/MACOS-RAYCAST-API-BATCHES.csv').open(newline='') as source:
        rows = [(row['package'], row['interface']) for row in csv.DictReader(source) if row['batch'] == '01']
    if len(rows) != 579 or len(set(rows)) != len(rows):
        raise ValueError('Batch 01 must account for 579 distinct entries')
    sdk_bytes = api_archive.read_bytes()
    if hashlib.sha256(sdk_bytes).hexdigest() != 'bf3dba2b5aaada428f22026623c3c787aae036bcc18c5e50baf09f13a39b514f':
        raise ValueError('Expected official @raycast/api 2.11.1 archive')
    with tarfile.open(fileobj=io.BytesIO(sdk_bytes)) as archive:
        text = archive.extractfile('package/types/index.d.ts').read().decode()
    icon_block = re.search(r'(?m)^export declare enum Icon \{([\s\S]*?)^\}', text).group(1)
    icons = dict(re.findall(r'^\s+(\w+) = "([^"]+)"', icon_block, flags=re.M))
    if {'Icon.' + name for name in icons} != {name for _, name in rows if name.startswith('Icon.')}:
        raise ValueError('Icon declarations and coverage rows differ')
    expected = json.loads(subprocess.check_output(['node', str(fixture/'Batch01Expected.cjs')], timeout=10))
    expected.update(rows=rows, sdkIcons=icons)
    (task/'batch-01-expected.json').write_text(json.dumps(expected, ensure_ascii=False))
    bundle_reviewed_fixture(host, task, compiler_archive, 'Batch01')
    return len(rows)


def bundle_reviewed_fixture(host, task, compiler_archive, command):
    fixture = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM2'
    shutil.copyfile(fixture/(command + '.mjs'), task/(command + '.mjs'))
    if not (task/'node_modules').exists():
        subprocess.run([str(host), 'reviewed-adapter', str(task)], check=True, timeout=10)
    compiler = task/'fixture-esbuild'
    if not compiler.exists():
        with tarfile.open(fileobj=io.BytesIO(archive_bytes(compiler_archive))) as archive:
            compiler.write_bytes(archive.extractfile('package/bin/esbuild').read())
        compiler.chmod(0o700)
    aliases = []
    if command == 'Batch02Assets':
        for name in ['fs', 'node:fs']:
            aliases += [f'--alias:{name}=./node_modules/@keylane/reviewed-assets/index.js',
                        f'--alias:{name}/promises=./node_modules/@keylane/reviewed-assets/promises.js']
    subprocess.run([str(compiler), command + '.mjs', '--bundle', '--platform=neutral', '--format=iife',
                    '--global-name=__keylaneCommandExports', '--outfile=' + command + '.js', *aliases],
                   cwd=task, capture_output=True, check=True, timeout=10)


def bundle_react_fixture(task, archive_directory):
    # Fixture dependencies only. Production dependency admission is unchanged.
    hashes = {
        'react': '2178ec02d41c09f60b5a7dc21844787afd0a41f268faa6ea9ac7a06ccf64eca6',
        'react-reconciler': '9f41ac53213ff6cfab8be60cea2513572893a15b0e976c63f42571a97b494323',
        'scheduler': '8aac2da6decb09c1dacf8c106f62d2fb4454fbb1fdf2f6fe6d4ef1a57b7c6914',
    }
    for name, digest in hashes.items():
        path = archive_directory/(name + '.tgz')
        with path.open('rb') as source:
            raw = source.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('Unexpected pinned React fixture archive: ' + name)
        with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
            for member in archive.getmembers():
                parts = Path(member.name).parts
                if not member.isfile() or not parts or parts[0] != 'package' or '..' in parts:
                    raise ValueError('Unexpected React fixture archive entry')
                output = task/'node_modules'/name/Path(*parts[1:])
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(archive.extractfile(member).read())
    source = ROOT/'Tests/ExtensionPrototype/MacOSRuntimeM2/Batch03React.cjs'
    shutil.copyfile(source, task/source.name)
    subprocess.run([str(task/'fixture-esbuild'), source.name, '--bundle', '--platform=neutral',
                    '--format=iife', '--global-name=__keylaneCommandExports',
                    '--define:process.env.NODE_ENV="production"', '--legal-comments=inline',
                    '--outfile=Batch03React.js'], cwd=task, check=True, capture_output=True, timeout=15)


def bundle_native_view_fixtures(host, task):
    # The previous fixture has no Raycast adapter yet. Use a separate project
    # for the exact production adapter so the two @raycast/api modules cannot mix.
    view = task/'view-adapter'
    view.mkdir()
    (view/'node_modules').mkdir()
    for name in ['react', 'react-reconciler', 'scheduler']:
        shutil.copytree(task/'node_modules'/name, view/'node_modules'/name)
    subprocess.run([str(host), 'reviewed-view-adapter', str(view)], check=True, timeout=10)
    for name in ['Batch03NativeView', 'Batch03LegacyRender', 'Batch03ViewEffects']:
        shutil.copyfile(ROOT/'Tests/ExtensionPrototype/MacOSRuntimeM2'/f'{name}.tsx', view/f'{name}.tsx')
        subprocess.run([str(task/'fixture-esbuild'), f'{name}Entry.mjs', '--bundle', '--platform=neutral',
                        '--format=iife', '--global-name=__keylaneCommandExports', '--jsx=automatic', '--main-fields=module,main',
                        '--define:process.env.NODE_ENV="production"', '--legal-comments=inline',
                        f'--outfile={task}/{name}.js'], cwd=view, check=True, timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--batch-01', nargs=2, type=Path, metavar=('COMPILER_ARCHIVE', 'API_ARCHIVE'))
    parser.add_argument('--batch-02', type=Path, metavar='COMPILER_ARCHIVE')
    parser.add_argument('--batch-03', type=Path, metavar='COMPILER_ARCHIVE')
    parser.add_argument('--batch-03-react-archives', type=Path)
    args = parser.parse_args()
    if args.batch_03_react_archives and not args.batch_03:
        parser.error('--batch-03-react-archives requires --batch-03')
    identity = broker.m0.resolve_identity()
    cases = {}
    with broker.slots.owned_directory() as task:
        app = task/'Host.app'
        host = app/'Contents/MacOS/host'
        runtime = app/'Contents/Helpers/KeylaneExtensionRun.app'
        helper = runtime/'Contents/MacOS/keylane-extension-run'
        host.parent.mkdir(parents=True)
        helper.parent.mkdir(parents=True)
        host_id = 'org.keylane.tests.runtime-m2.host'
        for bundle, identifier, executable in [(runtime, 'org.keylane.tests.runtime-m2.helper', helper.name),
                                                (app, host_id, host.name)]:
            (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': executable, 'CFBundlePackageType': 'APPL',
                'CFBundleShortVersionString': '9.8.7'}))
        shutil.copy2(args.products/helper.name, helper)
        rights = {'com.apple.security.app-sandbox': True}
        sandbox = task/'sandbox.plist'
        sandbox.write_bytes(plistlib.dumps(rights))
        empty = task/'empty.plist'
        empty.write_bytes(plistlib.dumps({}))
        provisional = task/'identity-check'
        shutil.copy2(helper, provisional)
        sign = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none']
        subprocess.run([*sign, str(provisional)], check=True, capture_output=True)
        detail = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(provisional)], stderr=subprocess.STDOUT, text=True)
        team = next(line.split('=', 1)[1] for line in detail.splitlines() if line.startswith('TeamIdentifier='))
        constraint = task/'parent.plist'
        constraint.write_bytes(plistlib.dumps({'signing-identifier': host_id, 'team-identifier': team}))
        subprocess.run([*sign, '--entitlements', str(sandbox), '--launch-constraint-parent', str(constraint), str(runtime)],
                       check=True, capture_output=True)
        digest = hashlib.sha256(helper.read_bytes()).hexdigest()
        constants = task/'Digest.swift'
        requirement = f'anchor apple generic and identifier "org.keylane.tests.runtime-m2.helper" and certificate leaf = H"{identity}"'
        constants.write_text('enum FixtureSigning { static let digest = ' + json.dumps(digest)
                             + '; static let requirement = ' + json.dumps(requirement) + ' }\n')
        compile_result = subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos26.0',
                        '-package-name', 'keylane_macos_runtime_design', '-I', str(args.products),
                        str(args.products/'KeylaneCore.o'), str(constants),
                        str(ROOT/'Tests/ExtensionPrototype/MacOSRuntimeM2/DriverHost.swift'),
                        '-o', str(host)], capture_output=True, text=True)
        if compile_result.returncode:
            raise RuntimeError(compile_result.stderr)
        subprocess.run([*sign, '--entitlements', str(empty), str(app)], check=True, capture_output=True)
        broker.m0.verify_signature(runtime, identity, rights)
        broker.m0.verify_signature(app, identity, {})
        rows_verified = None
        if args.batch_01:
            rows_verified = verify_batch_01(host, task, *args.batch_01)
            for mode in ['batch-01-values', 'batch-01-no-grants']:
                result = subprocess.run([str(host), mode, str(task)], timeout=10, capture_output=True, text=True)
                if result.returncode:
                    print(f'{mode}: {result.stderr}')
                cases[mode] = result.returncode == 0 and not broker.helper_pids(helper)
        if args.batch_02:
            bundle_reviewed_fixture(host, task, args.batch_02, 'Batch02')
            bundle_reviewed_fixture(host, task, args.batch_02, 'Batch02Assets')
            for mode in ['batch-02-write', 'batch-02-failed', 'batch-02-reopen', 'batch-02-denied', 'batch-02-ordinary-only',
                         'batch-02-files-write', 'batch-02-files-reopen', 'batch-02-files-denied']:
                result = subprocess.run([str(host), mode, str(task)], timeout=10, capture_output=True, text=True)
                if result.returncode:
                    print(f'{mode}: {result.stderr}')
                cases[mode] = result.returncode == 0 and not broker.helper_pids(helper)
        if args.batch_03:
            bundle_reviewed_fixture(host, task, args.batch_03, 'Batch03HUD')
            for mode in ['view-session-updates', 'view-session-stale-action', 'view-session-revoked',
                         'view-session-feedback-confirm-toast', 'view-session-feedback-dismiss',
                         'view-session-feedback-blocked', 'view-session-feedback-blocked-toast',
                         'batch-03-hud-allowed', 'batch-03-hud-denied']:
                result = subprocess.run([str(host), mode, str(task)], timeout=10, capture_output=True, text=True)
                if result.returncode:
                    print(f'{mode}: {result.stderr}')
                cases[mode] = result.returncode == 0 and not broker.helper_pids(helper)
        if args.batch_03_react_archives:
            bundle_react_fixture(task, args.batch_03_react_archives)
            bundle_native_view_fixtures(host, task)
            for mode in ['view-session-react', 'view-session-react-group-denied',
                         'view-production-confirm', 'view-production-decline', 'view-production-legacy',
                         'view-production-revoked', 'view-production-no-grant', 'view-production-no-presentation',
                         'view-production-effects', 'view-production-effects-denied']:
                result = subprocess.run([str(host), mode, str(task)], timeout=10, capture_output=True, text=True)
                if result.returncode:
                    print(f'{mode}: {result.stderr}')
                cases[mode] = result.returncode == 0 and not broker.helper_pids(helper)
        for mode in ['normal', 'exception', 'digest', 'helper-digest', 'replay', 'timeout',
                     'capabilities', 'capability-denied', 'capability-error', 'capability-revoked', 'registry-capabilities',
                     'default-async', 'default-rejection', 'default-pending']:
            started_at = time.monotonic()
            result = subprocess.run([str(host), mode, str(task)], timeout=10, capture_output=True)
            cases[mode] = result.returncode == 0 and not broker.helper_pids(helper)
            if mode == 'timeout':
                cases[mode] = cases[mode] and 4.5 <= time.monotonic() - started_at < 8
        result = subprocess.run([str(helper)], input=b'1', timeout=8, capture_output=True)
        cases['wrongParent'] = result.returncode < 0 and not result.stdout
        for mode in ['cancel', 'parent-loss', 'registry-disable']:
            with subprocess.Popen([str(host), mode, str(task)]) as parent:
                try:
                    end = time.monotonic() + 3
                    while parent.poll() is None and time.monotonic() < end and not broker.helper_pids(helper):
                        time.sleep(0.01)
                    started = bool(broker.helper_pids(helper))
                    stopping_at = time.monotonic()
                    if mode == 'cancel':
                        (task/'cancel').touch()
                    elif mode == 'registry-disable':
                        (task/'disable').touch()
                    else:
                        parent.kill()
                    status = parent.wait(timeout=8)
                    broker.confirm_helper_exit(helper)
                    cases[mode] = (started and status == (-9 if mode == 'parent-loss' else 0)
                                   and time.monotonic() - stopping_at < 3)
                finally:
                    if parent.poll() is None:
                        parent.kill()
                    parent.wait(timeout=5)
                    broker.confirm_helper_exit(helper)
        lock_path = task/'owner.lock'
        with lock_path.open('xb'):
            lock_path.chmod(0o600)
        with lock_path.open('rb') as contender, subprocess.Popen([str(host), 'owner-loss', str(task)]) as parent:
            child = None
            try:
                end = time.monotonic() + 3
                while parent.poll() is None and time.monotonic() < end:
                    children = broker.helper_pids(helper)
                    if len(children) == 1:
                        child = children[0]
                        break
                    time.sleep(0.01)
                if child is None:
                    raise RuntimeError('Owned helper did not start')
                def is_excluded():
                    try:
                        fcntl.flock(contender, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return True
                    fcntl.flock(contender, fcntl.LOCK_UN)
                    return False

                cases['secondHostExcludedDuringRun'] = is_excluded()
                parent.kill()
                parent.wait(timeout=5)
                # The helper may already have exited when the kernel returns
                # from wait. Acquiring while the exact helper is alive fails.
                excluded = is_excluded()
                cases['noTakeoverBeforeHelperExit'] = excluded or child not in broker.helper_pids(helper)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=5)
                broker.confirm_helper_exit(helper)
            fcntl.flock(contender, fcntl.LOCK_SH | fcntl.LOCK_NB)
            cases['ownerReleasedAfterHelperExit'] = True
        broker.m0.verify_signature(runtime, identity, rights)
        broker.m0.verify_signature(app, identity, {})
    report = {'fixtureOnly': True, 'scope': 'M2 native no-view and supervised view processes', 'cases': cases,
              'gate': 'incomplete' if all(cases.values()) else 'blocked'}
    if rows_verified and cases['batch-01-values'] and cases['batch-01-no-grants']:
        report['batch01JavaScriptEntries'] = rows_verified
    with args.report.open('x') as output:
        json.dump(report, output, indent=2)
    print(json.dumps(report))
    return 0 if all(cases.values()) else 2


if __name__ == '__main__':
    raise SystemExit(main())
