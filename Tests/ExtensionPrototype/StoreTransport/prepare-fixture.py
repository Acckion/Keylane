"""Build a controlled ingress or fixed-stage image. No source executes on host."""
import importlib.util, pathlib, subprocess, sys, tempfile, shutil
here = pathlib.Path(__file__).resolve().parent
guest = here.parent / 'LinuxGuest'
spec = importlib.util.spec_from_file_location('prepare_guest', guest / 'prepare.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
cache, output = map(lambda p: pathlib.Path(p).resolve(), sys.argv[1:3])
stage = len(sys.argv)>3 and sys.argv[3] in ('stage','real')
real = len(sys.argv)>3 and sys.argv[3]=='real'
output.mkdir(parents=True, exist_ok=True)
# Only read the existing pinned package cache; all products go to our scratch dir.
for name in ('apks',):
    if not (output/name).exists(): (output/name).symlink_to(cache/name, target_is_directory=True)
with tempfile.TemporaryDirectory(dir=output) as temporary:
    root = pathlib.Path(temporary)
    module.prepare(cache/'kernel.apk', output, root, 'run', here/'guest-fixture.cjs')
    # Repack with the same isolation init; diagnostic writes only, no authority changes.
    init_source = (guest/'init.c').read_text().replace('int fd = socket(AF_VSOCK', 'fprintf(stderr, \"fixture connecting\\n\"); int fd = socket(AF_VSOCK').replace('if (mount(\"proc\"', 'fprintf(stderr, \"fixture modules loaded\\n\"); if (mount(\"proc\"')
    diagnostic = output/'fixture-init.c'
    diagnostic.write_text(init_source)
    subprocess.run(['zig','cc','-target','aarch64-linux-musl','-static','-Os',str(diagnostic),'-o',str(root/'init')],check=True,env={**module.os.environ,'ZIG_GLOBAL_CACHE_DIR':str(output/'zig-cache')})
    if stage:
        import tarfile
        archive_path=cache/'npm'/'esbuild.tgz'
        module.require_hash(archive_path,'d5e01d210e026823d559e2b82554cdcdab6fd87c4a57b519b392ef183c1f87fd')
        with tarfile.open(archive_path,'r:gz') as archive: (root/'esbuild').write_bytes(archive.extractfile('package/bin/esbuild').read())
        (root/'esbuild').chmod(0o555)
        subprocess.run(['zig','cc','-target','aarch64-linux-musl','-static','-Os',str(here/'stage-init.c'),'-o',str(root/'init')],check=True,env={**module.os.environ,'ZIG_GLOBAL_CACHE_DIR':str(output/'zig-cache')})
        for name in ('stage-receiver.cjs','stage-output.cjs'): shutil.copyfile(here/name,root/name)
        # Fixed trusted stub, never package-supplied dependencies.
        stub=root/'node_modules'/'@raycast'/'api';stub.mkdir(parents=True,exist_ok=True)
        if real:
            icu=cache/'icu-data-en.apk'
            module.require_hash(icu,'2c2d36d47c82d0f6cff1b549044fe3562f327f944971ef367b9c40eeb35aa6e8')
            with tarfile.open(icu,'r:gz') as archive:
                archive.extract('usr/share/icu/76.1/icudt76l.dat',root,filter='data')
            import re
            pending=['raycast-api.cjs']; seen=set()
            while pending:
                name=pending.pop()
                if name in seen: continue
                if '/' in name or not name.endswith('.cjs'): raise ValueError('trusted module path')
                seen.add(name); content=(guest/name).read_text()
                shutil.copyfile(guest/name,root/name)
                pending.extend(re.findall(r'require\([\'"]\./([^\'"]+)[\'"]\)',content))
            (root/'real-api').write_text('real-no-view-v1')
            (stub/'index.js').write_text('module.exports=require("/raycast-api.cjs");\n')
            (output/'real-api').write_text('real-no-view-v1')
        else:
            (stub/'index.js').write_text("exports.showToast=async ({title})=>{global.fixtureResult=title};\n")
    for name in ('package-data.cjs','receive-package.cjs'):
        shutil.copyfile(here/name, root/name)
        (root/name).chmod(0o444)
    shutil.copyfile(here/'guest-fixture.cjs', root/'view.cjs')
    (root/'view.cjs').chmod(0o444)
    entries = sorted(str(p.relative_to(root)) for p in root.rglob('*'))
    with (output/'ingress.cpio').open('wb') as archive:
        subprocess.run(['cpio','-o','-H','newc'],cwd=root,input=('\n'.join(entries)+'\n').encode(),stdout=archive,check=True)
