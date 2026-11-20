import io
import os
import pathlib
import stat
import tempfile
import unittest

from store_guest_newc import write_newc


def records(archive):
    offset = 0
    while offset < len(archive):
        if archive[offset:offset + 6] != b'070701':
            raise AssertionError('newc magic')
        sizes = [int(archive[i:i + 8], 16) for i in range(offset + 6, offset + 110, 8)]
        offset += 110
        name = archive[offset:offset + sizes[11] - 1]
        offset = (offset + sizes[11] + 3) & ~3
        data = archive[offset:offset + sizes[6]]
        offset = (offset + sizes[6] + 3) & ~3
        yield name, sizes, data
    if offset != len(archive):
        raise AssertionError('newc alignment')


class StoreGuestNewcTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = pathlib.Path(directory.name)

    def archive(self):
        stream = io.BytesIO()
        write_newc(self.root, stream)
        return stream.getvalue()

    def test_stable_bytes_sorted_paths_and_normalized_metadata(self):
        (self.root / 'z').write_bytes(b'inert payload')
        (self.root / 'bin').mkdir(mode=0o700)
        (self.root / 'bin/init').write_bytes(b'synthetic bytes, never executed')
        (self.root / 'bin/init').chmod(0o775)
        (self.root / 'link').symlink_to('/bin/init')
        first = self.archive()
        os.utime(self.root / 'bin/init', (17, 99))
        (self.root / 'bin/init').chmod(0o771)
        (self.root / 'bin').chmod(0o755)
        self.assertEqual(first, self.archive())
        result = list(records(first))
        self.assertEqual([item[0] for item in result], [b'bin', b'bin/init', b'link', b'z', b'TRAILER!!!'])
        self.assertEqual(result[1][1][1], stat.S_IFREG | 0o755)
        self.assertEqual(result[1][1][2:6], [0, 0, 1, 0])
        self.assertEqual(result[2][2], b'/bin/init')

    def test_unsafe_records_rejected(self):
        (self.root / 'link').symlink_to('../outside')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            self.archive()
        (self.root / 'link').unlink()
        os.mkfifo(self.root / 'pipe')
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            self.archive()

if __name__ == '__main__':
    unittest.main()
