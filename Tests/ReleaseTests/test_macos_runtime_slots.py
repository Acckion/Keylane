import copy
import errno
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('macos_runtime_slots', ROOT / 'scripts/verify-macos-runtime-slots.py')
slots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slots)


class MacOSRuntimeSlotTests(unittest.TestCase):
    def denied(self):
        names = ['spawnSystem', 'spawnNode', 'childHostRead', 'hostRead', 'hostWrite', 'symlinkRead', 'network', 'inheritedDescriptor']
        return dict(slotA={'cases': {name: {'allowed': False} for name in names}},
                    slotB={'cases': {'foreignSlotRead': {'allowed': False}}},
                    sameSlot={'cases': {'foreignSlotRead': {'allowed': False}}},
                    lifecycle={'hang': {'groupStopsTree': True}, 'detached': {'groupStopsTree': True}})

    def test_passing_new_subset_never_means_complete_m0(self):
        self.assertEqual(slots.verdict(self.denied()), ('incomplete', []))

    def test_reuse_residue_still_blocks_even_if_cross_slot_is_denied(self):
        report = self.denied()
        report['sameSlot']['cases']['foreignSlotRead']['allowed'] = True
        self.assertIn('slotReuseResidue', slots.verdict(report)[1])
        self.assertEqual(slots.verdict(report)[0], 'blocked')

    def test_cooperative_cleanup_does_not_hide_detached_escape(self):
        report = self.denied()
        report['lifecycle']['detached']['groupStopsTree'] = False
        self.assertEqual(slots.verdict(report), ('blocked', ['detachedEscapesGroup']))

    def test_each_negative_boundary_is_required(self):
        report = self.denied()
        for name in report['slotA']['cases']:
            changed = copy.deepcopy(report)
            changed['slotA']['cases'][name]['allowed'] = True
            self.assertIn(name, slots.verdict(changed)[1])
        report['slotB']['cases']['foreignSlotRead']['allowed'] = True
        self.assertIn('crossSlotRead', slots.verdict(report)[1])

    def test_missing_data_does_not_count_as_denial(self):
        report = self.denied()
        del report['slotA']['cases']['inheritedDescriptor']
        with self.assertRaises(KeyError):
            slots.verdict(report)

    def test_cleanup_retries_only_owned_enotempty_races(self):
        with patch.object(slots.tempfile, 'mkdtemp', return_value='/private/tmp/keylane-m0-slots-unit'), \
             patch.object(slots.shutil, 'rmtree', side_effect=[OSError(errno.ENOTEMPTY, 'race'), None]) as remove, \
             patch.object(slots.time, 'sleep'):
            with slots.owned_directory() as root:
                self.assertEqual(root.name, 'keylane-m0-slots-unit')
            self.assertEqual(remove.call_count, 2)
            self.assertTrue(all(call.args == (root,) for call in remove.call_args_list))

    def test_cleanup_does_not_hide_permission_failure(self):
        with patch.object(slots.tempfile, 'mkdtemp', return_value='/private/tmp/keylane-m0-slots-unit'), \
             patch.object(slots.shutil, 'rmtree', side_effect=PermissionError(errno.EACCES, 'denied')) as remove:
            with self.assertRaises(PermissionError):
                with slots.owned_directory():
                    pass
            self.assertEqual(remove.call_count, 1)

    def test_cleanup_retry_is_bounded(self):
        with patch.object(slots.tempfile, 'mkdtemp', return_value='/private/tmp/keylane-m0-slots-unit'), \
             patch.object(slots.shutil, 'rmtree', side_effect=OSError(errno.ENOTEMPTY, 'race')) as remove, \
             patch.object(slots.time, 'sleep'):
            with self.assertRaises(OSError):
                with slots.owned_directory():
                    pass
            self.assertEqual(remove.call_count, 3)
