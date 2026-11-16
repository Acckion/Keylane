"""Resolve and pin a real signing identity; never silently fall back to ad hoc."""
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
PIN = ROOT / '.signing-identity'

def signing_identity(*, require_developer_id=False):
    explicit = os.environ.get('KEYLANE_SIGNING_IDENTITY', '').strip()
    allow_adhoc = os.environ.get('KEYLANE_ALLOW_ADHOC') == '1'
    if require_developer_id and explicit in ('', '-'):
        raise SystemExit('发行构建必须指定 Developer ID Application 签名身份。')
    if explicit == '-' or (not explicit and allow_adhoc):
        if not allow_adhoc:
            raise SystemExit('临时签名会丢失升级授权；仅在明确设置 KEYLANE_ALLOW_ADHOC=1 时允许。')
        print('使用临时签名：升级后可能需要重新授权。')
        return '-'
    result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', result.stdout, re.M)
    requested = explicit or (PIN.read_text().strip() if PIN.exists() else '')
    if requested:
        matches = [(fingerprint, name) for fingerprint, name in identities if fingerprint.lower() == requested.lower() or name == requested]
    else:
        matches = [(fingerprint, name) for fingerprint, name in identities if name.startswith('Apple Development:')]
    if len(matches) != 1:
        raise SystemExit('未找到唯一且有效的固定签名身份。请设置 KEYLANE_SIGNING_IDENTITY 为证书指纹；不会自动退回临时签名。')
    fingerprint, name = matches[0]
    if require_developer_id and not name.startswith('Developer ID Application:'):
        raise SystemExit('发行构建必须使用 Developer ID Application 证书。')
    if not requested:
        temporary = PIN.with_suffix('.tmp')
        temporary.write_text(fingerprint + '\n')
        temporary.chmod(0o600)
        temporary.replace(PIN)
    print('使用固定代码签名身份。')
    return fingerprint
