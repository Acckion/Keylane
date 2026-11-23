import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('m1_gate',ROOT/'scripts/check-macos-build-m1.py')
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)


class M1AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.records={name:dict(fixtureOnly=True,installed=False,signaturesVerifiedBeforeAndAfter=True,
                               temporaryArtifactsRemoved=True,gate=status,cases=dict.fromkeys(gate.required(script),True))
                      for name,(script,_,status)in gate.GROUPS.items()}
        self.records['product'].update(productionRuntimeReady=False,publicExtensionsVerified=False)
        self.records['product']['cases']['cleaned']=True

    def test_m1_does_not_approve_execution(self):
        result=gate.assess(self.records)
        self.assertEqual(result['gate'],'M1-passed');self.assertIs(result['productionRuntimeReady'],False)
        self.assertIs(result['M2Started'],False);self.assertIs(result['publicExtensionsVerified'],False)

    def test_each_observation_failure_blocks(self):
        for group in self.records:
            for key in gate.required(gate.GROUPS[group][0]):
                records=copy.deepcopy(self.records);records[group]['cases'][key]=False
                self.assertFalse(gate.assess(records)['M1Complete'])

    def test_missing_numeric_unclean_or_enabled_evidence_fails_closed(self):
        for key in ['temporaryArtifactsRemoved','signaturesVerifiedBeforeAndAfter']:
            records=copy.deepcopy(self.records);records['product'][key]=False
            with self.assertRaises(ValueError):gate.assess(records)
        for value in [None,1,'true']:
            records=copy.deepcopy(self.records);records['product']['cases']['crossProcessCASOneWinner']=value
            with self.assertRaises(ValueError):gate.assess(records)
        for key in ['productionRuntimeReady','publicExtensionsVerified']:
            records=copy.deepcopy(self.records);records['product'][key]=True
            with self.assertRaises(ValueError):gate.assess(records)
        records=copy.deepcopy(self.records);records['product']['cases']['cleaned']=False
        with self.assertRaises(ValueError):gate.assess(records)

    def test_packaged_compiler_archive_requires_exact_sri(self):
        import extension_builder
        with tempfile.TemporaryDirectory(prefix='keylane-m1-archive-')as directory:
            archive=Path(directory)/'archive';archive.write_bytes(b'not an official compiler')
            with self.assertRaises(ValueError):extension_builder.archive_bytes(archive)
