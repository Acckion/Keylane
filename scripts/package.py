import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
from signing import signing_identity
from app_intents import extract_metadata
from versioning import load_version
from extension_builder import package_builder, builder_enabled, package_runtime, provisioned_rights
root = pathlib.Path(__file__).resolve().parent.parent
version = load_version()
distribution = os.environ.get('KEYLANE_DISTRIBUTION') == '1'
runtime_profile = os.environ.get('KEYLANE_EXTENSION_RUNTIME_PROVISION')
legacy_runtime = os.environ.get("KEYLANE_EXTENSION_RUNTIME_LEGACY_PREVIEW") == "1"
if legacy_runtime and (runtime_profile or distribution):
    raise ValueError("Legacy runtime preview requires a development signature and no provisioning profile")
identity = signing_identity(require_developer_id=distribution, require_apple_development=legacy_runtime)
runtime_rights = provisioned_rights(pathlib.Path(runtime_profile), 'org.keylane.launcher', identity) if runtime_profile else None
binary = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='keylane-', dir='/private/tmp') as directory:
    image_contents = pathlib.Path(directory) / 'image'
    app = image_contents / 'Keylane.app'
    executable = app / 'Contents/MacOS/Keylane'
    executable.parent.mkdir(parents=True)
    shutil.copyfile(binary, executable)
    executable.chmod(0o755)
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    extract_metadata(binary, resources, root)
    for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
        shutil.copyfile(root / name, resources / name)
    for name in ('EmojiCatalog.tsv', 'Unicode-LICENSE.txt'):
        shutil.copyfile(root / 'Resources' / name, resources / name)
    shutil.copytree(root / 'Resources/ModuleArtwork', resources / 'ModuleArtwork')
    metadata = dict(CFBundleExecutable='Keylane', CFBundleIdentifier='org.keylane.launcher', CFBundleName='Keylane', CFBundlePackageType='APPL', CFBundleShortVersionString=version['version'], CFBundleVersion=str(version['build']), LSMinimumSystemVersion='26.0', LSUIElement=True,
                    NSMicrophoneUsageDescription="仅在你主动开始语音翻译或听写时使用麦克风；云端听写会将录音发送至你选择的语音服务生成文字。",
                    NSSpeechRecognitionUsageDescription="在翻译中将语音转换为原文。",
                    NSCameraUsageDescription="在你打开相机时显示实时画面，并按你的操作拍摄照片。",
                    NSCameraUseContinuityCameraDeviceType=True,
                    NSDesktopFolderUsageDescription="将你拍摄的照片保存到桌面。",
                    NSContactsUsageDescription='在 Keylane 中搜索和管理系统联系人，并按你的操作新建或删除联系人。',
                    NSCalendarsFullAccessUsageDescription='读取系统日历，并按你的操作保存日程和提醒。', NSAppleEventsUsageDescription='读取 Finder 信息和快捷指令图标，搜索、新建和打开 Apple 备忘录，定位日程及添加受邀人，在专注会话期间屏蔽并恢复浏览器标签，或执行你选择的废纸篓、系统外观及电源操作。')
    metadata['CFBundleURLTypes'] = [dict(CFBundleURLName='org.keylane.ai-chat', CFBundleURLSchemes=['keylane'])]
    icon_metadata = pathlib.Path(directory) / 'IconInfo.plist'
    subprocess.run([
        'xcrun', 'actool', '--compile', str(resources), '--platform', 'macosx',
        '--minimum-deployment-target', metadata['LSMinimumSystemVersion'],
        '--app-icon', 'Keylane', '--output-partial-info-plist', str(icon_metadata),
        str(root / 'Resources/Keylane.icon'),
    ], check=True)
    with icon_metadata.open('rb') as file:
        metadata.update(plistlib.load(file))
    with (app/'Contents/Info.plist').open('wb') as file:
        plistlib.dump(metadata, file)
    architectures = subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()
    if builder_enabled(architectures,identity,distribution):
        package_builder(app,binary.parent/'keylane-extension-build',identity,archive=os.environ.get('KEYLANE_EXTENSION_COMPILER_ARCHIVE'),distribution=distribution)
    signing_options = ['--options', 'runtime', '--timestamp'] if distribution else ['--options','runtime','--timestamp=none']
    entitlements = root / 'Resources/Keylane.entitlements'
    if runtime_rights is not None or legacy_runtime:
        if architectures != 'arm64':
            raise ValueError('Runtime packaging requires an ARM64 build')
        package_runtime(app, binary.parent/'keylane-extension-run', identity,
                        distribution=distribution, legacy_preview=legacy_runtime)
    if runtime_rights is not None:
        shutil.copyfile(runtime_profile,app/'Contents/embedded.provisionprofile')
        rights = plistlib.loads(entitlements.read_bytes())
        rights.update(runtime_rights)
        entitlements = pathlib.Path(directory)/'host-entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(rights))
    subprocess.run(['codesign', '--force', '--sign', identity, *signing_options,
                    '--entitlements', str(entitlements), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    (image_contents / 'Applications').symlink_to('/Applications', target_is_directory=True)
    image = pathlib.Path(directory) / 'Keylane.dmg'
    subprocess.run([
        'hdiutil', 'create', '-srcfolder', str(image_contents), '-volname', 'Keylane',
        '-fs', 'HFS+', '-format', 'UDZO', str(image),
    ], check=True)
    if distribution:
        subprocess.run([
            'codesign', '--sign', identity, '--timestamp',
            '--identifier', 'org.keylane.launcher.dmg', str(image),
        ], check=True)
    shutil.move(image, output)
print(output)
