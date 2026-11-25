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
    subprocess.run([str(compiler), command + '.mjs', '--bundle', '--platform=neutral', '--format=iife',
                    '--global-name=__keylaneCommandExports', '--outfile=' + command + '.js'],
                   cwd=task, capture_output=True, check=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--batch-01', nargs=2, type=Path, metavar=('COMPILER_ARCHIVE', 'API_ARCHIVE'))
    args = parser.parse_args()
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
    report = {'fixtureOnly': True, 'scope': 'M2 native no-view process', 'cases': cases,
              'gate': 'incomplete' if all(cases.values()) else 'blocked'}
    if rows_verified and cases['batch-01-values'] and cases['batch-01-no-grants']:
        report['batch01JavaScriptEntries'] = rows_verified
    with args.report.open('x') as output:
        json.dump(report, output, indent=2)
    print(json.dumps(report))
    return 0 if all(cases.values()) else 2


if __name__ == '__main__':
    raise SystemExit(main())
