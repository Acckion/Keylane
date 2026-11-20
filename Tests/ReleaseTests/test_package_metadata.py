import ast
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def synthetic_metadata():
    source = (ROOT / 'scripts/package.py').read_text()
    # Compile without running packaging, signing, media, or filesystem operations.
    compile(source, 'scripts/package.py', 'exec')
    tree = ast.parse(source)
    values = [node.value for node in ast.walk(tree)
              if isinstance(node, ast.Assign)
              and any(isinstance(target, ast.Name) and target.id == 'metadata'
                      for target in node.targets)]
    if len(values) != 1:
        raise AssertionError('Expected one application metadata declaration')
    expression = ast.Expression(body=values[0])
    return eval(compile(expression, '<synthetic package metadata>', 'eval'),
                {'__builtins__': {}, 'dict': dict, 'str': str},
                {'version': {'version': '9.8.7', 'build': 42}})


class PackageMetadataTests(unittest.TestCase):
    def test_microphone_covers_explicit_translation_and_cloud_dictation(self):
        metadata = synthetic_metadata()
        description = metadata['NSMicrophoneUsageDescription']
        for scope in ['主动', '语音翻译', '听写', '录音', '发送', '选择']:
            with self.subTest(scope=scope):
                self.assertIn(scope, description)

    def test_translation_camera_and_version_metadata_are_preserved(self):
        metadata = synthetic_metadata()
        self.assertEqual(metadata['NSSpeechRecognitionUsageDescription'], '在翻译中将语音转换为原文。')
        self.assertEqual(metadata['NSCameraUsageDescription'], '在你打开相机时显示实时画面，并按你的操作拍摄照片。')
        self.assertEqual(metadata['CFBundleShortVersionString'], '9.8.7')
        self.assertEqual(metadata['CFBundleVersion'], '42')
