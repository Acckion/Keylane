import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('m1_build', ROOT/'scripts/verify-macos-build-m1.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class MacOSM1BuildTests(unittest.TestCase):
    def test_slice_success_never_completes_m1(self):
        self.assertEqual(probe.verdict(dict.fromkeys(probe.CASES, True)), ('incomplete', []))

    def test_each_failure_and_non_boolean_block(self):
        for key in probe.CASES:
            values = dict.fromkeys(probe.CASES, True); values[key] = False
            self.assertEqual(probe.verdict(values), ('blocked', [key]))
            for value in [None, 1, 'true']:
                values[key] = value
                with self.assertRaises(ValueError): probe.verdict(values)

    def test_compiler_archive_digest_checked_before_extraction(self):
        with tempfile.TemporaryDirectory(prefix='keylane-m1-digest-') as directory:
            root = Path(directory); archive = root/'compiler.tgz'; output = root/'compiler'
            archive.write_bytes(b'not a pinned compiler')
            with self.assertRaises(ValueError): probe.compiler(archive, output)
            self.assertFalse(output.exists())
