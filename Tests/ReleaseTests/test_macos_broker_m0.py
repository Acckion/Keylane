import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('broker_m0', ROOT / 'scripts/verify-macos-broker-m0.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class BrokerProbeTests(unittest.TestCase):
    def test_all_observed_checks_do_not_approve_production(self):
        self.assertEqual(probe.verdict(dict.fromkeys(probe.CASES, True)), ('incomplete', []))

    def test_each_boundary_failure_blocks(self):
        for key in probe.CASES:
            with self.subTest(key=key):
                cases = dict.fromkeys(probe.CASES, True)
                cases[key] = False
                self.assertEqual(probe.verdict(cases), ('blocked', [key]))

    def test_missing_or_non_boolean_observations_are_rejected(self):
        with self.assertRaises(RuntimeError):
            probe.verdict({})
        for bad in [None, 0, 1, 'true']:
            cases = dict.fromkeys(probe.CASES, True)
            cases['fixtureProcessesExited'] = bad
            with self.assertRaises(RuntimeError):
                probe.verdict(cases)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native Swift authority fixture requires macOS')
    def test_native_authority_rechecks_at_each_boundary(self):
        # Synthetic in-memory records only. No signing, user data, or OS service.
        fixture = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM0/Broker'
        with tempfile.TemporaryDirectory(prefix='keylane-broker-unit-') as directory:
            binary = str(Path(directory) / 'authority-tests')
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', directory + '/cache',
                            str(fixture / 'Authority.swift'), str(fixture / 'AuthorityTests.swift'),
                            '-o', binary], check=True, capture_output=True, text=True, timeout=90)
            result = subprocess.run([binary], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('PASS broker admission', result.stdout)
