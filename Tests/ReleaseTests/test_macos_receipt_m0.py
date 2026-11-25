import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('receipt_m0', ROOT/'scripts/verify-macos-receipt-m0.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ReceiptProbeTests(unittest.TestCase):
    def test_observed_subset_never_approves_production(self):
        self.assertEqual(probe.verdict(dict.fromkeys(probe.CASES, True)), ('incomplete', []))

    def test_each_failed_check_blocks(self):
        for key in probe.CASES:
            cases = dict.fromkeys(probe.CASES, True)
            cases[key] = False
            self.assertEqual(probe.verdict(cases), ('blocked', [key]))

    def test_missing_and_numeric_observations_rejected(self):
        with self.assertRaises(RuntimeError): probe.verdict({})
        for value in [0, 1, None, 'true']:
            cases = dict.fromkeys(probe.CASES, True)
            cases['sealedFirstPartyExecutes'] = value
            with self.assertRaises(RuntimeError): probe.verdict(cases)

    def test_changed_source_identity_cannot_fall_back_to_branch(self):
        with mock.patch.object(probe.subprocess, 'check_output', return_value='0'*40) as read:
            with self.assertRaises(RuntimeError): probe.extract_source(Path('/unused'))
            read.assert_called_once()

    @unittest.skipUnless(sys.platform == 'darwin', 'Native child supervision requires macOS')
    def test_exit_observation_and_failed_sampling_remain_distinct(self):
        fixture=ROOT/'Tests/ExtensionPrototype/MacOSRuntimeM0/Transport'
        with tempfile.TemporaryDirectory(prefix='keylane-stop-unit-') as directory:
            for variant in [[], ['-DM0_FORCE_SAMPLE_FAILURE']]:
                binary=str(Path(directory)/('stop-fault' if variant else 'stop-normal'))
                subprocess.run(['xcrun','clang','-O2',*variant,str(fixture/'MemoryGuard.c'),
                                str(fixture/'MemoryGuardTests.c'),'-o',binary],check=True,capture_output=True,timeout=30)
                result=subprocess.run([binary],check=True,capture_output=True,text=True,timeout=15)
                self.assertIn('PASS 50 child-exit races',result.stdout)
