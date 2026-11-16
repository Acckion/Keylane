"""Shared version metadata for validation and packaging (standard library only)."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def parse_version(text):
    value = json.loads(text)
    version, build = value.get('version'), value.get('build')
    if not isinstance(version, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('version must be MAJOR.MINOR.PATCH without leading zeros')
    if type(build) is not int or not 1 <= build <= 999999999:
        raise ValueError('build must be a positive integer up to 999999999')
    # Apple CFBundleShortVersionString has three numeric components.
    return {'version': version, 'build': build}


def load_version():
    return parse_version((ROOT / 'version.json').read_text())


def ensure_increase(current, previous):
    if tuple(map(int, current['version'].split('.'))) <= tuple(map(int, previous['version'].split('.'))):
        raise ValueError('a main release must increase version')
    if current['build'] <= previous['build']:
        raise ValueError('a main release must increase build')
