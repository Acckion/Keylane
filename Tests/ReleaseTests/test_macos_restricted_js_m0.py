import errno
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('restricted_js_m0', ROOT / 'scripts/verify-macos-restricted-js-m0.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class RestrictedJSProbeTests(unittest.TestCase):
    def test_all_subprobes_pass_still_does_not_approve_production(self):
        self.assertEqual(probe.verdict(dict.fromkeys(probe.REQUIRED_CASES, True)), ('incomplete', []))

    def test_each_boundary_failure_blocks(self):
        for key in probe.REQUIRED_CASES:
            cases = dict.fromkeys(probe.REQUIRED_CASES, True)
            cases[key] = False
            self.assertEqual(probe.verdict(cases), ('blocked', [key]))

    def test_missing_or_numeric_boolean_is_not_a_passing_probe(self):
        for bad in [None, 0, 1, 'true']:
            cases = dict.fromkeys(probe.REQUIRED_CASES, True)
            cases['nativeFileDenied'] = bad
            with self.assertRaises(RuntimeError):
                probe.verdict(cases)
        with self.assertRaises(RuntimeError):
            probe.verdict({})

    def test_native_file_denial_requires_a_real_permission_error(self):
        self.assertTrue(probe.native_file_denied({'tested': True, 'allowed': False, 'errno': errno.EPERM}))
        self.assertTrue(probe.native_file_denied({'tested': True, 'allowed': False, 'errno': errno.EACCES}))
        self.assertFalse(probe.native_file_denied({'tested': True, 'allowed': False, 'errno': errno.ENOENT}))
        self.assertFalse(probe.native_file_denied({'tested': True, 'allowed': True, 'errno': 0}))

    def test_native_numeric_zero_cannot_be_misclassified_as_a_denial(self):
        with self.assertRaises(RuntimeError):
            probe.native_file_denied({'tested': True, 'allowed': 0, 'errno': errno.EPERM})
