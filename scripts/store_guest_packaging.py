"""Prepare an optional nested Store guest using only repo-pinned assets.

The existing build is unaffected when no guest directory is requested. A
fixture cache does not qualify: the reviewed lock and release-built helper
must first exist. The main app never receives the virtualization entitlement.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import unicodedata
from urllib.parse import urlsplit

IDENTIFIER = 'org.keylane.launcher.store-guest'
HELPER_NAME = 'KeylaneStoreGuest'
ASSETS = {'Image': 128 * 1024 * 1024, 'ingress.cpio': 512 * 1024 * 1024}
NOTICES = 'StoreGuestNotices.json'
NOTICE_LIMIT = 4 * 1024 * 1024


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key in Store guest metadata')
        result[key] = value
    return result


def _load_json(raw):
    return json.loads(raw.decode('utf-8'), object_pairs_hook=_unique_object)


def _digest(value):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) is not None


def _validate_notice_bundle(raw, lock):
    if hashlib.sha256(raw).hexdigest() != lock['notices']:
        raise ValueError('Store guest notices do not match pinned SHA-256')
    bundle = _load_json(raw)
    if not isinstance(bundle, dict) or set(bundle) != {'version', 'recipe', 'files', 'components'} or type(bundle['version']) is not int or bundle['version'] != 1:
        raise ValueError('unsupported Store guest notice bundle shape')
    if bundle['recipe'] != lock['recipe'] or bundle['files'] != lock['files']:
        raise ValueError('Store guest notices are not bound to the locked recipe and runtime assets')
    components = bundle['components']
    if not isinstance(components, list) or not components:
        raise ValueError('Store guest notice bundle contains no components')
    covered = set()
    ids = set()
    for component in components:
        if not isinstance(component, dict) or set(component) != {'id', 'assets', 'notice', 'sources'}:
            raise ValueError('invalid Store guest notice component')
        identifier = component['id']
        if not isinstance(identifier, str) or not re.fullmatch(r'[a-z0-9][a-z0-9._+-]{0,127}', identifier) or identifier in ids:
            raise ValueError('invalid or duplicate Store guest notice component identifier')
        ids.add(identifier)
        assets = component['assets']
        if not isinstance(assets, list) or not assets or not all(isinstance(asset, str) and asset in ASSETS for asset in assets) or len(set(assets)) != len(assets):
            raise ValueError('invalid Store guest notice asset references')
        covered.update(assets)
        notice = component['notice']
        if not isinstance(notice, str) or not any(unicodedata.category(char)[0] in 'LNPS' for char in notice):
            raise ValueError('Store guest component is missing inline notice text')
        try:
            notice.encode('utf-8')
        except UnicodeEncodeError as error:
            raise ValueError('Store guest component has invalid UTF-8 notice text') from error
        sources = component['sources']
        if not isinstance(sources, list) or not sources:
            raise ValueError('Store guest component is missing corresponding-source references')
        urls = set()
        for source in sources:
            if not isinstance(source, dict) or set(source) != {'url', 'sha256'} or not _digest(source['sha256']):
                raise ValueError('invalid Store guest corresponding-source reference')
            url = source['url']
            if not isinstance(url, str) or not re.fullmatch(r'https://[!-~]+', url) or any(char in url for char in ('\\', '?', '#')):
                raise ValueError('invalid Store guest corresponding-source URL')
            parsed = urlsplit(url)
            if not parsed.hostname or not re.fullmatch(r'[a-zA-Z0-9.-]+(?::443)?', parsed.netloc) or parsed.path in ('', '/') or url in urls:
                raise ValueError('invalid or duplicate Store guest corresponding-source URL')
            urls.add(url)
    if covered != set(ASSETS):
        raise ValueError('Store guest notices do not cover exactly the locked runtime assets')


def _checked_file(path, maximum, *, dir_fd=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        mode = os.fstat(descriptor)
        if not stat.S_ISREG(mode.st_mode) or not 0 < mode.st_size <= maximum:
            raise ValueError(f'not a bounded regular file: {pathlib.Path(path).name}')
        return os.fdopen(descriptor, 'rb'), mode.st_size
    except BaseException:
        os.close(descriptor)
        raise


def load_lock(lock_path):
    file, _ = _checked_file(lock_path, 8 * 1024)
    with file:
        raw = file.read(8 * 1024 + 1)
    if len(raw) > 8 * 1024:
        raise ValueError('Store guest lock exceeded 8 KiB')
    lock = _load_json(raw)
    if not isinstance(lock, dict) or set(lock) != {'version', 'recipe', 'files', 'notices'} or type(lock.get('version')) is not int or lock['version'] != 2:
        raise ValueError('unsupported Store guest lock shape')
    if not isinstance(lock['recipe'], str) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,63}', lock['recipe']):
        raise ValueError('invalid Store guest recipe identifier')
    files = lock['files']
    if not isinstance(files, dict) or set(files) != set(ASSETS):
        raise ValueError('Store guest lock must pin exactly Image and ingress.cpio')
    if not all(_digest(value) for value in files.values()) or not _digest(lock['notices']):
        raise ValueError('malformed Store guest resource digest')
    return lock


def copy_pinned_assets(asset_directory, lock, resource_directory):
    """Copy and hash the same bytes; no unlisted resource or symlink is used."""
    directory = os.open(asset_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        file, size = _checked_file(NOTICES, NOTICE_LIMIT, dir_fd=directory)
        with file:
            notices = file.read(NOTICE_LIMIT + 1)
        if len(notices) != size:
            raise ValueError('Store guest notices changed while reading')
        _validate_notice_bundle(notices, lock)
        for name, maximum in ASSETS.items():
            file, size = _checked_file(name, maximum, dir_fd=directory)
            with file, (resource_directory / name).open('xb') as output:
                total = 0
                digest = hashlib.sha256()
                for chunk in iter(lambda: file.read(128 * 1024), b''):
                    total += len(chunk)
                    if total > size:
                        raise ValueError(f'Store guest resource changed while reading {name}')
                    digest.update(chunk)
                    output.write(chunk)
            if total != size or digest.hexdigest() != lock['files'][name]:
                raise ValueError(f'Store guest resource does not match pinned SHA-256: {name}')

        with (resource_directory / NOTICES).open('xb') as output:
            output.write(notices)
    finally:
        os.close(directory)


def stage_store_guest(app, root, asset_directory, keylane_binary, identity, signing_options):
    if not identity or identity == '-':
        raise ValueError('Store guest requires Apple-anchored application signing; no ad-hoc fallback')
    lock_path = root / 'Resources/StoreGuest.lock.json'
    if not lock_path.exists():
        raise ValueError('Store guest distribution assets are not qualified: reviewed Resources/StoreGuest.lock.json absent')
    lock = load_lock(lock_path)
    helper_binary = keylane_binary.parent / HELPER_NAME
    if not helper_binary.is_file() or helper_binary.is_symlink():
        raise ValueError('release-built KeylaneStoreGuest helper missing; the test harness is not accepted')
    bundle = app / f'Contents/Helpers/{HELPER_NAME}.app'
    resources = bundle / 'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=False)
    copy_pinned_assets(asset_directory, lock, resources)
    executable = bundle / f'Contents/MacOS/{HELPER_NAME}'
    executable.parent.mkdir()
    shutil.copyfile(helper_binary, executable)
    executable.chmod(0o755)
    with (bundle / 'Contents/Info.plist').open('xb') as plist:
        plistlib.dump(dict(CFBundleIdentifier=IDENTIFIER, CFBundleExecutable=HELPER_NAME,
                            CFBundlePackageType='APPL', KeylaneStoreGuestRecipe=lock['recipe']), plist)
    subprocess.run(['codesign', '--force', '--sign', identity, *signing_options,
                    '--entitlements', str(root / 'Resources/KeylaneStoreGuest.entitlements'),
                    str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    return bundle
