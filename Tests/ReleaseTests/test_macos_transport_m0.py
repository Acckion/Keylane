import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('transport_m0', ROOT / 'scripts/verify-macos-transport-m0.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class TransportProbeTests(unittest.TestCase):
    def test_complete_subset_remains_incomplete(self):
        self.assertEqual(probe.verdict(dict.fromkeys(probe.CASES, True)), ('incomplete', []))

    def test_every_failed_boundary_blocks(self):
        for key in probe.CASES:
            with self.subTest(key=key):
                cases = dict.fromkeys(probe.CASES, True)
                cases[key] = False
                self.assertEqual(probe.verdict(cases), ('blocked', [key]))

    def test_missing_or_non_boolean_observation_is_not_evidence(self):
        with self.assertRaises(RuntimeError): probe.verdict({})
        for bad in [None, 0, 1, 'true']:
            cases = dict.fromkeys(probe.CASES, True)
            cases['blockedRPCParentDeath'] = bad
            with self.assertRaises(RuntimeError): probe.verdict(cases)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native framing requires macOS')
    def test_native_framing_distinguishes_truncation_and_eof(self):
        fixture = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM0/Broker'
        with tempfile.TemporaryDirectory(prefix='keylane-frame-unit-') as directory:
            binary = str(Path(directory) / 'frame-tests')
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', directory+'/cache',
                            str(fixture/'FrameChannel.swift'), str(fixture/'FrameTests.swift'),
                            '-o', binary], check=True, capture_output=True, timeout=90)
            result = subprocess.run([binary], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('PASS bounded framing', result.stdout)
