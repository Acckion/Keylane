import pathlib, plistlib, shutil, subprocess, sys, tempfile, zipfile
from signing import signing_identity
from versioning import load_version
root = pathlib.Path(__file__).resolve().parent.parent
version = load_version()
identity = signing_identity()
binary = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='keylane-', dir='/private/tmp') as directory:
    app = pathlib.Path(directory) / 'Keylane.app'
    executable = app / 'Contents/MacOS/Keylane'
    executable.parent.mkdir(parents=True)
    shutil.copyfile(binary, executable)
    executable.chmod(0o755)
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / 'LICENSE', resources / 'LICENSE')
    for name in ('EmojiCatalog.tsv', 'Unicode-LICENSE.txt'):
        shutil.copyfile(root / 'Resources' / name, resources / name)
    metadata = dict(CFBundleExecutable='Keylane', CFBundleIdentifier='org.keylane.launcher', CFBundleName='Keylane', CFBundlePackageType='APPL', CFBundleShortVersionString=version['version'], CFBundleVersion=str(version['build']), LSMinimumSystemVersion='26.0', LSUIElement=True,
                    NSContactsUsageDescription='在 Keylane 中查找联系人并复制电话号码和邮箱。',
                    NSCalendarsFullAccessUsageDescription='读取系统日历并展示日程摘要。', NSAppleEventsUsageDescription='读取你在 Finder 中选择的文件，或在你授权后读取 Apple 快捷指令的图标。')
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
    subprocess.run(['codesign','--force','--sign',identity,'--timestamp=none',str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
        for path in app.rglob('*'):
            if path.is_file(): archive.write(path,path.relative_to(app.parent))
print(output)
