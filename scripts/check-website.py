"""Check buildless Pages assets, fragments, language and release contracts."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'website'
RELEASE = 'https://github.com/Acckion/Keylane/releases/tag/v1.0.2-beta.1'

class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.path, self.ids, self.refs = path, set(), []
        self.lang = None
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == 'html': self.lang = a.get('lang')
        if 'id' in a:
            assert a['id'] not in self.ids, f'Duplicate id: {self.path}: {a["id"]}'
            self.ids.add(a['id'])
        if tag == 'img': assert 'alt' in a, f'Missing alt: {self.path}'
        for k in ('href', 'src'):
            if k in a: self.refs.append(a[k])

pages = {}
for path in SITE.rglob('*.html'):
    page = Page(path)
    text = path.read_text()
    page.feed(text)
    assert RELEASE in text and 'releases/latest' not in text
    assert '891ab2c' in text and '877ca22' in text and 'GPL-3.0-or-later' in text
    assert 'width=device-width' in text
    pages[path] = page
assert pages[SITE/'index.html'].lang == 'zh-CN'
assert pages[SITE/'en/index.html'].lang == 'en'
for path, page in pages.items():
    for ref in page.refs:
        u = urlsplit(ref)
        if u.scheme or u.netloc: continue
        assert not u.path.startswith('/'), f'Root-relative URL breaks /Keylane/: {ref}'
        target = (path.parent / unquote(u.path)).resolve() if u.path else path
        if target.is_dir(): target /= 'index.html'
        assert target.is_relative_to(SITE), f'Escapes website: {ref}'
        assert target.exists(), f'Missing asset: {path}: {ref}'
        if u.fragment: assert u.fragment in pages[target].ids, f'Missing fragment: {ref}'
print(f'PASS: {len(pages)} language pages; local links, fragments, image alt, /Keylane/ resources and release/license markers')
