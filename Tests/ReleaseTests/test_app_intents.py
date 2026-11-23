import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from app_intents import FOCUS_PROTOCOL, constant_value_files, validate_metadata


class AppIntentsTests(unittest.TestCase):
    def test_metadata_requires_system_filter_parameters_and_entity(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            action = {'systemProtocols': [FOCUS_PROTOCOL], 'fullyQualifiedTypeName': 'Keylane.KeylaneFocusFilter',
                      'parameters': [{'name': name} for name in ['categories', 'mode', 'goal']]}
            data = {'actions': {'KeylaneFocusFilter': action}, 'entities': {'FocusCategoryEntity': {}},
                    'enums': [{'identifier': 'FocusFilterMode', 'cases': [{'identifier': 'block'}, {'identifier': 'allow'}]}]}
            (directory / 'version.json').write_text(json.dumps({'version': '3.0', 'toolsVersion': 'test'}))
            def write():
                (directory / 'extract.actionsdata').write_text(json.dumps(data))
            write(); validate_metadata(directory)
            action['systemProtocols'] = []; write()
            with self.assertRaises(ValueError): validate_metadata(directory)
            action['systemProtocols'] = [FOCUS_PROTOCOL]; action['parameters'].pop(); write()
            with self.assertRaises(ValueError): validate_metadata(directory)
            action['parameters'].append({'name': 'goal'}); data['entities'] = {}; write()
            with self.assertRaises(ValueError): validate_metadata(directory)

    def test_rejects_arbitrary_binary_without_matching_swiftpm_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'Keylane'; binary.touch()
            with self.assertRaises(ValueError): constant_value_files(binary)

    def test_reads_only_the_matching_release_product_and_architecture(self):
        for target in ('Keylane.build', 'Keylane-p.build'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'out'
                binary = output / 'Products/Release/Keylane'
                binary.parent.mkdir(parents=True)
                binary.touch()
                objects = output / 'Intermediates.noindex/Keylane.build'
                wanted = objects / f'Release/{target}/Objects-normal/arm64/Keylane-primary.swiftconstvalues'
                decoys = [
                    objects / f'Release/{target}/Objects-normal/x86_64/Keylane-primary.swiftconstvalues',
                    objects / f'Debug/{target}/Objects-normal/arm64/Keylane-primary.swiftconstvalues',
                    objects / 'Release/Keylane-ABC-testable.build/Objects-normal/arm64/Keylane-primary.swiftconstvalues',
                    objects / 'Release/KeylaneCore.build/Objects-normal/arm64/KeylaneCore-primary.swiftconstvalues',
                ]
                for path in [wanted, *decoys]:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                with patch('app_intents.platform.machine', return_value='arm64'):
                    self.assertEqual(constant_value_files(binary), [wanted])
                    wanted.unlink()
                    with self.assertRaisesRegex(ValueError, 'missing Focus'):
                        constant_value_files(binary)

    def test_rejects_mixed_current_and_legacy_release_products(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'out'
            binary = output / 'Products/Release/Keylane'
            binary.parent.mkdir(parents=True)
            binary.touch()
            objects = output / 'Intermediates.noindex/Keylane.build/Release'
            for target in ('Keylane.build', 'Keylane-p.build'):
                path = objects / f'{target}/Objects-normal/arm64/Keylane-primary.swiftconstvalues'
                path.parent.mkdir(parents=True)
                path.touch()
            with patch('app_intents.platform.machine', return_value='arm64'):
                with self.assertRaisesRegex(ValueError, 'ambiguous Focus'):
                    constant_value_files(binary)
