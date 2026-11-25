"""Keep shipped command and settings artwork references resolvable."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ArtworkResourcesTests(unittest.TestCase):
    def test_all_named_artwork_references_have_a_shipped_resource(self):
        source = (ROOT / 'Sources/Keylane/ModuleArtwork.swift').read_text()
        names = set()
        for dictionary in ('settingsNames', 'commandNames'):
            body = source.split(f'private static let {dictionary} = [', 1)[1].split('\n    ]', 1)[0]
            names.update(re.findall(r': "([^"]+)"', body))
        names.update(re.findall(r'image\("([^"]+)"\)', source))
        # Resolved from the local application bundle at runtime.
        names.discard('keylane-app')
        self.assertTrue(names)
        for name in sorted(names):
            with self.subTest(resource=name):
                self.assertTrue((ROOT / 'Resources/ModuleArtwork' / f'{name}.png').is_file())
