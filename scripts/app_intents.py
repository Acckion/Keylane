"""Extract App Intents metadata from the same SwiftPM build that supplied the binary."""
import json
import pathlib
import platform
import subprocess
import tempfile

FOCUS_PROTOCOL = 'com.apple.link.systemProtocol.FocusConfiguration'
METADATA_FILES = {'extract.actionsdata', 'version.json'}


def object_directory(binary):
    binary = pathlib.Path(binary).resolve(strict=True)
    # Xcode SwiftPM's release symlink resolves to out/Products/Release/Keylane.
    if binary.name != 'Keylane' or binary.parent.parent.name != 'Products' or binary.parents[2].name != 'out':
        raise ValueError('App Intents require a binary from the Xcode SwiftPM Products directory')
    configuration = binary.parent.name
    return binary.parents[2] / 'Intermediates.noindex/Keylane.build' / configuration / 'Keylane-p.build/Objects-normal' / platform.machine()


def validate_metadata(directory):
    directory = pathlib.Path(directory)
    if not directory.is_dir() or {p.name for p in directory.iterdir()} != METADATA_FILES:
        raise ValueError('Missing or unexpected App Intents metadata files')
    data = json.loads((directory / 'extract.actionsdata').read_text())
    action = data.get('actions', {}).get('KeylaneFocusFilter', {})
    if FOCUS_PROTOCOL not in action.get('systemProtocols', []):
        raise ValueError('Keylane Focus filter is missing its system registration')
    if action.get('fullyQualifiedTypeName') != 'Keylane.KeylaneFocusFilter':
        raise ValueError('Unexpected Focus filter type identity')
    if {p.get('name') for p in action.get('parameters', [])} != {'categories', 'mode', 'goal'}:
        raise ValueError('Incomplete Focus filter parameters')
    entities = data.get('entities', {})
    if 'FocusCategoryEntity' not in entities:
        raise ValueError('Focus category entity is missing')
    modes = next((enum for enum in data.get('enums', []) if enum.get('identifier') == 'FocusFilterMode'), {})
    if {case.get('identifier') for case in modes.get('cases', [])} != {'block', 'allow'}:
        raise ValueError('Focus filter mode choices are missing')
    version = json.loads((directory / 'version.json').read_text())
    if not version.get('version') or not version.get('toolsVersion'):
        raise ValueError('Invalid App Intents metadata version')
    return data


def extract_metadata(binary, resources, root):
    objects = object_directory(binary)
    values = sorted(objects.glob('*.swiftconstvalues'))
    if not values:
        raise ValueError('Build is missing Focus filter constant values; rebuild Keylane first')
    sources = sorted((pathlib.Path(root) / 'Sources/Keylane').glob('*.swift'))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    swiftc = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    xcode_build = subprocess.check_output(['xcodebuild', '-version'], text=True).split('Build version ', 1)[1].strip()
    with tempfile.TemporaryDirectory(prefix='keylane-intents-') as temporary:
        source_list = pathlib.Path(temporary) / 'sources.list'
        values_list = pathlib.Path(temporary) / 'values.list'
        source_list.write_text(''.join(str(p) + '\n' for p in sources))
        values_list.write_text(''.join(str(p) + '\n' for p in values))
        subprocess.run([
            'xcrun', 'appintentsmetadataprocessor', '--output', str(resources),
            '--toolchain-dir', str(swiftc.parents[2]), '--module-name', 'Keylane',
            '--sdk-root', sdk, '--xcode-version', xcode_build, '--platform-family', 'macOS',
            '--deployment-target', '26.0', '--target-triple', platform.machine() + '-apple-macos26.0',
            '--source-file-list', str(source_list), '--swift-const-vals-list', str(values_list),
        ], check=True)
    validate_metadata(pathlib.Path(resources) / 'Metadata.appintents')
