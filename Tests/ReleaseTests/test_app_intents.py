import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from app_intents import FOCUS_PROTOCOL, object_directory, validate_metadata


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
            with self.assertRaises(ValueError): object_directory(binary)
