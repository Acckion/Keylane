import copy
import importlib.util
import datetime
import hashlib
import plistlib
from types import SimpleNamespace
from unittest.mock import patch
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
        self.records['product'].update(productionRuntimeReady=False,publicExtensionsVerified=False,
                                       protectedStorage='data-protection-keychain-v2',provisionedFixtureOnly=True)
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

    def test_legacy_storage_cannot_satisfy_new_acceptance(self):
        for value in [None,'legacy-Keychain-ACL']:
            records=copy.deepcopy(self.records);records['product']['protectedStorage']=value
            with self.assertRaises(ValueError):gate.assess(records)

    def test_provision_selection_checks_identity_platform_expiry_and_group(self):
        probe_spec=importlib.util.spec_from_file_location('m1_product',ROOT/'scripts/verify-macos-product-m1.py')
        probe=importlib.util.module_from_spec(probe_spec);probe_spec.loader.exec_module(probe)
        certificate=b'synthetic-public-certificate'
        profile={'Platform':['OSX'],'ExpirationDate':datetime.datetime(2030,1,1),
                 'DeveloperCertificates':[certificate],'Entitlements':{'com.apple.developer.team-identifier':'TESTTEAM01',
                 'com.apple.application-identifier':'TESTTEAM01.org.keylane.fixture','keychain-access-groups':['TESTTEAM01.*']}}
        now=datetime.datetime(2026,11,23,tzinfo=datetime.timezone.utc)
        def resolve(value):
            with patch.object(probe.subprocess,'run',return_value=SimpleNamespace(stdout=plistlib.dumps(value))):
                return probe.provisioned_rights(Path('synthetic'), 'org.keylane.fixture',hashlib.sha1(certificate).hexdigest(),now=now)
        self.assertEqual(resolve(profile)['keychain-access-groups'],['TESTTEAM01.org.keylane.fixture'])
        for key,value in [('Platform',['iOS']),('ExpirationDate',datetime.datetime(2020,1,1)),('DeveloperCertificates',[b'other'])]:
            modified=copy.deepcopy(profile);modified[key]=value
            with self.assertRaises(ValueError):resolve(modified)
        for key,value in [('com.apple.application-identifier','TESTTEAM01.other'),('keychain-access-groups',['TESTTEAM01.other'])]:
            modified=copy.deepcopy(profile);modified['Entitlements'][key]=value
            with self.assertRaises(ValueError):resolve(modified)
