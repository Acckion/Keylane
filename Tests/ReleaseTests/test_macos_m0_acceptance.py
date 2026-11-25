import copy
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]

def module(script):
    spec=importlib.util.spec_from_file_location(script.replace('-','_'),ROOT/'scripts'/script)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

gate=module('check-macos-runtime-m0.py')

class M0AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.decision={'engine':'restricted-JavaScriptCore','strictIsolation':True,'vmAllowed':False,'compatibility':'explicit-subset'}
        self.evidence={}
        for name,(script,_,attribute)in gate.MODULES.items():
            self.evidence[name]={'fixtureOnly':True,'installed':False,'gate':'incomplete',
                'cases':dict.fromkeys(gate.required_cases(script,attribute),True),
                'signaturesVerifiedBeforeAndAfter':True,'temporaryArtifactsRemoved':True}

    def test_feasibility_does_not_approve_production(self):
        result=gate.assess(self.decision,self.evidence)
        self.assertEqual(result['gate'],'feasibility-passed')
        self.assertIs(result['productionRuntimeReady'],False)
        self.assertIs(result['publicExtensionsVerified'],False)
        self.assertIs(result['M1Started'],False)

    def test_every_boundary_failure_blocks(self):
        for name,record in self.evidence.items():
            for key in record['cases']:
                data=copy.deepcopy(self.evidence);data[name]['cases'][key]=False
                self.assertEqual(gate.assess(self.decision,data)['gate'],'blocked')

    def test_missing_numeric_or_unsigned_evidence_cannot_pass(self):
        for value in [None,1,0,'true']:
            data=copy.deepcopy(self.evidence);data['trust']['cases']['oneCASWinner']=value
            with self.assertRaises(ValueError):gate.assess(self.decision,data)
        data=copy.deepcopy(self.evidence);data['trust']['signaturesVerifiedBeforeAndAfter']=False
        with self.assertRaises(ValueError):gate.assess(self.decision,data)
        with self.assertRaises(ValueError):gate.assess(self.decision,{})

    def test_no_implicit_engine_or_trust_switch(self):
        for field,value in [('engine','Node'),('strictIsolation',False),('vmAllowed',True),('compatibility','full')]:
            decision=dict(self.decision);decision[field]=value
            with self.assertRaises(ValueError):gate.assess(decision,self.evidence)

    def test_each_subset_remains_incomplete(self):
        for script in ['verify-macos-trust-m0.py','verify-macos-boundary-m0.py','verify-macos-privacy-m0.py','verify-macos-compatibility-m0.py']:
            probe=module(script)
            self.assertEqual(probe.verdict(dict.fromkeys(probe.CASES,True)),('incomplete',[]))
            for key in probe.CASES:
                data=dict.fromkeys(probe.CASES,True);data[key]=False
                self.assertEqual(probe.verdict(data),('blocked',[key]))

    def test_plaintext_or_failed_scanner_control_blocks(self):
        for key in ['scannerFindsControl','noObservedPlaintextAfterExecution']:
            data=copy.deepcopy(self.evidence);data['privacy']['cases'][key]=False
            self.assertEqual(gate.assess(self.decision,data)['gate'],'blocked')
