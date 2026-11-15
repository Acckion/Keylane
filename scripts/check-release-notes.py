#!/usr/bin/env python3
"""Validate the Markdown source shared by GitHub Releases and the app."""
import argparse
import re
from versioning import ROOT, load_version

CHANGE_SECTIONS = {'新增', '改进', '修复'}
REQUIRED_SECTIONS = {'兼容性与已知限制', '验证'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    tag = parser.parse_args().tag
    base = 'v' + load_version()['version']
    if re.fullmatch(re.escape(base) + r'(?:-(?:alpha|beta)\.[1-9][0-9]*)?', tag) is None:
        parser.error('tag must match version.json and use the stable, alpha.N or beta.N format')
    path = ROOT / 'docs' / 'releases' / (tag + '.md')
    if not path.is_file():
        parser.error(f'missing release notes: {path.relative_to(ROOT)}')
    lines = path.read_text(encoding='utf-8').strip().splitlines()
    if not lines or not lines[0].startswith('# ') or lines[0] == '# 本次发布主题':
        parser.error('release notes must start with a specific release title')
    sections = {}
    current = None
    for line in lines[1:]:
        if line.startswith('## '):
            current = line[3:].strip()
            if current in sections:
                parser.error(f'duplicate release notes section: {current}')
            sections[current] = []
        elif current and re.match(r'^-\s+\S', line):
            sections[current].append(line)
    for section in REQUIRED_SECTIONS:
        if not sections.get(section):
            parser.error(f'missing list items under {section}')
    changes = [item for section in CHANGE_SECTIONS for item in sections.get(section, [])]
    if not changes or not all(re.match(r'^- \*\*[^*]+\*\*[：:]\s*\S', item) for item in changes):
        parser.error('list concrete changes under 新增, 改进 or 修复 as "- **模块**：具体改动"')
    print(f'Release notes for {tag}: OK')


if __name__ == '__main__':
    main()
