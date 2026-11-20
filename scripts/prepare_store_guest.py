"""Build an unqualified Store guest candidate from an existing pinned cache.

Run from a trusted source checkout with the reviewed local aarch64 build
toolchain. No fetch, npm install, package scripts, execution of an extension,
distribution lock, or signing occurs here.
"""
import argparse
import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from store_guest_newc import write_newc

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROTOTYPE = ROOT / 'Tests/ExtensionPrototype/LinuxGuest'
STAGE = ROOT / 'Tests/ExtensionPrototype/StoreTransport'
ESBUILD_HASH = 'd5e01d210e026823d559e2b82554cdcdab6fd87c4a57b519b392ef183c1f87fd'
ICU_HASH = '2c2d36d47c82d0f6cff1b549044fe3562f327f944971ef367b9c40eeb35aa6e8'
ICU_MEMBER = 'usr/share/icu/76.1/icudt76l.dat'


def prepare(cache, output):
    if output.exists() or output.is_symlink():
        raise ValueError('Store guest candidate requires a fresh output directory')
    spec = importlib.util.spec_from_file_location('keylane_pinned_guest', PROTOTYPE / 'prepare.py')
    existing_guest = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(existing_guest)
    output.mkdir()
    with tempfile.TemporaryDirectory(prefix='stage-', dir=output) as temporary:
        work = pathlib.Path(temporary)
        root = work / 'initramfs'
        root.mkdir()
        existing_guest.prepare(cache / 'kernel.apk', work, root, 'probe')
        existing_guest.stage_node(root, cache / 'apks')
        tool = cache / 'npm/esbuild.tgz'
        existing_guest.require_hash(tool, ESBUILD_HASH)
        with tarfile.open(tool, 'r:gz') as archive:
            member = archive.getmember('package/bin/esbuild')
            if not member.isfile() or not 0 < member.size <= 24 * 1024 * 1024:
                raise ValueError('unexpected pinned esbuild package')
            with archive.extractfile(member) as source, (root / 'esbuild').open('xb') as destination:
                shutil.copyfileobj(source, destination)
        (root / 'esbuild').chmod(0o555)
        icu = cache / 'icu-data-en.apk'
        existing_guest.require_hash(icu, ICU_HASH)
        with tarfile.open(icu, 'r:gz') as archive:
            if not archive.getmember(ICU_MEMBER).isfile():
                raise ValueError('unexpected pinned ICU package')
            archive.extract(ICU_MEMBER, root, filter='data')

        for name in ('store-stage.cjs', 'project-stage.cjs', 'receive-package.cjs', 'package-data.cjs'):
            shutil.copyfile(STAGE / name, root / name)
        # Exact first-party runtime module closure. No sample bundle, Store
        # extension, dynamic fetch or user file is put into the signed tree.
        pending = ['raycast-api.cjs']
        seen = set()
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            if not re.fullmatch(r'[a-z0-9-]+\.cjs', name):
                raise ValueError('unexpected API module')
            seen.add(name)
            source = PROTOTYPE / name
            shutil.copyfile(source, root / name)
            pending.extend(re.findall(r'''require\(["']\./([^"']+)["']\)''', source.read_text()))
        api = root / 'node_modules/@raycast/api'
        api.mkdir(parents=True)
        (api / 'index.js').write_text('module.exports = require("/raycast-api.cjs");\n')
        # Limit this candidate to the currently repo-owned no-view bridge; no
        # compatibility declaration, React/UI or arbitrary SDK implementation.
        subprocess.run([
            'zig', 'cc', '-target', 'aarch64-linux-musl', '-static', '-Os', '-Wl,--build-id=none',
            str(STAGE / 'store-init.c'), '-o', str(root / 'init')
        ], check=True, env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(work / 'zig-cache')})
        with (output / 'ingress.cpio').open('xb') as archive:
            write_newc(root, archive)
        shutil.copyfile(work / 'Image', output / 'Image')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cache', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    if not args.cache.is_dir():
        parser.error('existing pinned cache required')
    prepare(args.cache.resolve(), args.output.absolute())


if __name__ == '__main__':
    main()
