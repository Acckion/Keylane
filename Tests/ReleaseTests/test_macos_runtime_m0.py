import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('macos_runtime_m0', ROOT / 'scripts/verify-macos-runtime-m0.py')
m0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m0)


class MacOSRuntimeM0Tests(unittest.TestCase):
    def denied(self):
        names = ['hostRead', 'hostWrite', 'symlinkRead', 'network', 'spawnSystem', 'spawnNode', 'childHostRead']
        return {'cases': {name: {'allowed': False} for name in names}}

    def test_missing_security_coverage_cannot_approve_runtime(self):
        first = self.denied()
        second = {'cases': {'crossInvocationRead': {'allowed': False}}}
        self.assertEqual(m0.classify(first, second, {'keychain': 'not-tested'})[0], 'incomplete')
        self.assertEqual(m0.classify(first, second, {})[0], 'incomplete')

    def test_each_os_boundary_failure_blocks_even_with_complete_coverage(self):
        for name in self.denied()['cases']:
            first = self.denied()
            first['cases'][name]['allowed'] = True
            gate, blockers = m0.classify(first, {'cases': {'crossInvocationRead': {'allowed': False}}}, {key: 'tested' for key in m0.REQUIRED_COVERAGE})
            self.assertEqual(gate, 'blocked')
            self.assertIn(name, blockers)

    def test_shared_helper_container_is_not_per_extension_storage_isolation(self):
        gate, blockers = m0.classify(self.denied(), {'cases': {'crossInvocationRead': {'allowed': True}}}, {key: 'tested' for key in m0.REQUIRED_COVERAGE})
        self.assertEqual((gate, blockers), ('blocked', ['sharedContainer']))

    def test_omitted_probe_is_not_interpreted_as_denial(self):
        first = self.denied()
        del first['cases']['network']
        with self.assertRaises(KeyError):
            m0.classify(first, {'cases': {'crossInvocationRead': {'allowed': False}}}, {key: 'tested' for key in m0.REQUIRED_COVERAGE})

    def test_tampered_cached_runtime_is_rejected_before_unpacking(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'bad.tar.gz'
            archive.write_bytes(b'not an approved runtime')
            with self.assertRaisesRegex(RuntimeError, 'digest mismatch'):
                m0.download_node(root, archive)
            self.assertFalse((root / 'node').exists())
