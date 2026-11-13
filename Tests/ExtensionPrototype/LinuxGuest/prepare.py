"""Build an initramfs using the pinned Alpine aarch64 linux-virt APK."""
import gzip
import hashlib
import json
import os
import shutil
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile

KERNEL_SHA256 = "dc01531450938a224f8cc369da67197aad4919d0841fb80754c40e6b6fb6adab"
MODULE_DIR = "lib/modules/6.12.117-0-virt/kernel"
MODULES = [
    "drivers/virtio/virtio_mmio",
    "net/vmw_vsock/vsock",
    "net/vmw_vsock/vmw_vsock_virtio_transport_common",
    "net/vmw_vsock/vmw_vsock_virtio_transport",
]


def require_hash(path, expected):
    with path.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != expected:
            raise SystemExit(f"SHA-256 mismatch: {path.name}")


def stage_reviewed_assets(destination, manifest):
    if manifest is None:
        return
    if manifest.stat().st_size > 32768:
        raise SystemExit("reviewed assets manifest is too large")
    entries = json.loads(manifest.read_text())
    if not isinstance(entries, dict) or len(entries) > 64:
        raise SystemExit("invalid reviewed assets manifest")
    total = 0
    for name, digest in entries.items():
        parts = name.split("/")
        if (len(name.encode()) > 240 or any(part in ("", ".", "..") for part in parts)
                or any(ord(c) < 32 or ord(c) == 127 or c == chr(92) for c in name)
                or not isinstance(digest, str) or len(digest) != 64
                or any(c not in "0123456789abcdef" for c in digest)):
            raise SystemExit("invalid reviewed asset entry")
        path = manifest.parent.joinpath(*parts)
        if path.resolve(strict=True) != path or not path.is_file():
            raise SystemExit("reviewed asset must be a regular file inside the manifest directory")
        with path.open("rb") as file:
            data = file.read(262145)
        total += len(data)
        if len(data) > 262144 or total > 1048576:
            raise SystemExit("reviewed asset size limit exceeded")
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f"SHA-256 mismatch: {name}")
        target = destination.joinpath(*parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o444)
    for directory in destination.rglob("*"):
        if directory.is_dir():
            directory.chmod(0o555)


def stage_node(root, packages):
    for line in Path(__file__).with_name("node-packages.sha256").read_text().splitlines():
        digest, name = line.split()
        package = packages / name
        require_hash(package, digest)
        with tarfile.open(package, "r:gz") as archive:
            for entry in archive:
                if entry.name == "usr/bin/node" or (
                    entry.name.startswith(("lib/", "usr/lib/")) and (entry.isfile() or entry.issym())
                ):
                    archive.extract(entry, root, filter="data")


def stage_npm_package(package, digest, destination, source_prefix="package/dist/"):
    require_hash(package, digest)
    with tarfile.open(package, "r:gz") as archive:
        for entry in archive:
            if not entry.isfile() or not (
                entry.name in ("package/package.json", "package/wrapper.mjs")
                or entry.name.startswith(source_prefix)
            ):
                continue
            path = destination / entry.name.removeprefix("package/")
            if not path.resolve().is_relative_to(destination):
                raise SystemExit(f"unsafe npm package path: {package.name}")
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(entry) as source, path.open("wb") as output:
                shutil.copyfileobj(source, output)


def stage_build(root, packages, source=None, phase="build"):
    esbuild = packages / "esbuild.tgz"
    require_hash(esbuild, "d5e01d210e026823d559e2b82554cdcdab6fd87c4a57b519b392ef183c1f87fd")
    with tarfile.open(esbuild, "r:gz") as archive:
        (root / "esbuild").write_bytes(archive.extractfile("package/bin/esbuild").read())
        (root / "esbuild").chmod(0o555)
    if phase == "view-build":
        for name, digest in (
            ("chmod.tsx", "0c996ac57110b5898b3abd52ad8ee9690afc4561372aea9c0e576a10e8db4ba2"),
            ("permissions.ts", "b3ed6d29108df134b8dcf485f63ffee71db9688f4da149a00eeefe2d9ac931f6"),
        ):
            path = source / name
            require_hash(path, digest)
            shutil.copyfile(path, root / name)
        return
    if phase == "menu-bar-build":
        for name, digest in (
            ("index.tsx", "70c9f96a94937f89796d1c416675ba5a7838ec782418bd1fa58ac822d68a9d93"),
            ("utils/time.ts", "6e578a075ee61e472c6196b20e67b1140874a085eafdb46e4c28fdd82aeb791c"),
        ):
            path = source / name
            require_hash(path, digest)
            target = root / ("menu-bar.tsx" if name == "index.tsx" else name)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        stage_npm_package(packages / "date-fns.tgz",
                          "32704d42d5df17f2e43c299b9da4cfd12f703ed7a0d4f215a0cc832955c4e36a",
                          root / "node_modules" / "date-fns", source_prefix="package/esm/")
        return
    if phase == "uuid-suite-build":
        for name, digest in (
            ("generate.tsx", "44df6f214a13dfc6f03a8c2eb0bd9ea7522f57862aa69c5e76d2dfc0b891fc68"),
            ("generateV5.tsx", "38d73705be1eb25aed9a8180ea2d30bb5b8ab6b692d0627fcc8f5091e674100b"),
            ("generateV7.tsx", "d02fe7d3b32b4a09adca5b193c87e5aa77b8023e15db439efd9523bf8dee2904"),
            ("generateUlid.tsx", "054e1343abf5fb4606165e28ad26f86557176c33768a193de4a9129550a7a2d5"),
            ("generateTypeID.ts", "e8f842c56d6a20f7c21549bc190cdfbfe346be0eec557287e222103c2d9a5ebf"),
            ("parseTypeID.ts", "225e0b830685eb24c9e3ce7130f6f1173d2d560e3659c0c55d33358245c9da04"),
            ("packTypeID.ts", "c1b06005a46d5cd760f6ffb5dee4f96c998accc98facdfe1dfb5d3a473499094"),
            ("viewHistory.tsx", "98d7442853dbeade26c55b6dfb2357fe1b1e6223a069b89be4cf5f3425670494"),
            ("uuidHistory.ts", "05b0adcf80b33c86b400172f642cb31a7e20395a51db3d215349c6e47b8fa526"),
            ("utils/uuidUtils.ts", "8b0e1a54faf86027417ef8b63c661c42d5cf2d8807295bd79ea886403cc93a36"),
        ):
            path = source / name
            require_hash(path, digest)
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        shutil.copyfile(Path(__file__).with_name("uuid-suite.ts"), root / "uuid-suite.ts")
        for line in Path(__file__).with_name("uuid-suite-packages.sha256").read_text().splitlines():
            digest, name, module = line.split()
            stage_npm_package(packages / name, digest, root / "node_modules" / module)
        return
    if source is not None:
        require_hash(source, "e2ad057e843336f7a1f25bb662dd9cf41df234edf00754e0784fbd9da11887d7")
        shutil.copyfile(source, root / "dependency.ts")
        (root / "dependency.ts").chmod(0o444)
        return
    stage_npm_package(packages / "uuid.tgz", "ec2013a661d5d449a872f259453bd59f1e0f30b60c57048949405b71914a1dc7",
                      root / "node_modules" / "uuid")
    source = root / "dependency.ts"
    shutil.copyfile(Path(__file__).with_name("dependency.ts"), source)
    source.chmod(0o444)


def prepare(apk, output, root, phase, source=None, asset_manifest=None):
    require_hash(apk, KERNEL_SHA256)
    (root / "dev").mkdir()
    (root / "proc").mkdir(exist_ok=True)
    (root / "modules").mkdir(exist_ok=True)
    with tarfile.open(apk, "r:gz") as archive:
        wrapped = archive.extractfile("boot/vmlinuz-virt").read()
        if wrapped[4:8] != b"zimg" or wrapped[24:28] != b"gzip":
            raise SystemExit("unexpected Alpine kernel format")
        offset, size = struct.unpack_from("<II", wrapped, 8)
        kernel = gzip.decompress(wrapped[offset:offset + size])
        if kernel[56:60] != b"ARM\x64":
            raise SystemExit("expected an AArch64 Linux Image")
        (output / "Image").write_bytes(kernel)
        for module in MODULES:
            data = archive.extractfile(f"{MODULE_DIR}/{module}.ko.gz").read()
            (root / "modules" / f"{Path(module).name}.ko").write_bytes(gzip.decompress(data))
    subprocess.run([
        "zig", "cc", "-target", "aarch64-linux-musl", "-static", "-Os",
        str(Path(__file__).with_name("init.c").resolve()), "-o", str(root / "init"),
    ], check=True, env={**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(output / "zig-cache")})
    if phase != "probe":
        stage_node(root, output / "apks")
        if phase in ("view", "uuid-suite"):
            icu = output / "icu-data-en.apk"
            require_hash(icu, "2c2d36d47c82d0f6cff1b549044fe3562f327f944971ef367b9c40eeb35aa6e8")
            with tarfile.open(icu, "r:gz") as archive:
                archive.extract("usr/share/icu/76.1/icudt76l.dat", root, filter="data")
        shutil.copyfile(Path(__file__).with_name("node-stage.cjs"), root / "node-stage.cjs")
        if phase in ("build", "uuid-build", "view-build", "uuid-suite-build", "menu-bar-build"):
            stage_build(root, output / "npm", source, phase)
        elif phase in ("noview", "view", "uuid-suite", "menu-bar"):
            assets = root / "assets"
            assets.mkdir()
            stage_reviewed_assets(assets, asset_manifest)
            assets.chmod(0o555)
            digest = {
                "noview": "270da7e4e85f0e4e65d20c31d7de75bb659f4a2d844ecbbc64a8c1a434ffb329",
                "view": "d80a2d8778b08e333746d81f944e33444861f98b1b01ab4b47958fc1adfaa9a5",
                "menu-bar": "3550d4ee8750cf7c2d8e2de53ed724bb18766e086f457b4cd5f074b565d741d5",
                "uuid-suite": "2c3e8eb86889ab00bff645ad365fb34e55fca1668d67b027d874b6353dd26fc5",
            }[phase]
            require_hash(source, digest)
            shutil.copyfile(source, root / "sample.cjs")
            (root / "sample.cjs").chmod(0o444)
            scripts = ("no-view.cjs",) if phase == "noview" else (
                "view.cjs", "view-api.cjs", "menu-bar.cjs", "grid-api.cjs", "list-api.cjs",
                "view-filter.cjs", "form-api.cjs", "action-api.cjs", "dropdown-api.cjs", "open-api.cjs", "list-metadata.cjs", "navigation-api.cjs", "create-actions.cjs", "date-action.cjs", "push-navigation.cjs",
                "finder-reveal.cjs", "trash-action.cjs", "open-with-clipboard.cjs", "quick-look-action.cjs", "clipboard-read.cjs", "clipboard-write.cjs", "image-api.cjs", "window-management.cjs",
            )
            common = ("raycast-api.cjs", "environment.cjs", "toast.cjs", "presentation-values.cjs", "icon-values.cjs",
                      "storage-compat.cjs", "broker-local-storage.cjs", "foundation-api.cjs", "cache-api.cjs", "utilities-cache.cjs", "raycast-utils.cjs", "utilities-visual-feedback.cjs", "utilities-hooks.cjs", "utilities-data-hooks.cjs", "utilities-runtime-hooks.cjs", "utilities-deeplinks.cjs", "applications-api.cjs", "diagnostics-api.cjs")
            for name in (*scripts, *common):
                shutil.copyfile(Path(__file__).with_name(name), root / name)
            api = root / "node_modules" / "@raycast" / "api"
            api.mkdir(parents=True)
            adapter = "raycast-api" if phase == "noview" else "view-api"
            (api / "index.js").write_text(f'module.exports = require("/{adapter}.cjs");\n')
            utils = api.with_name("utils")
            utils.mkdir()
            (utils / "index.js").write_text(
                f'module.exports = require("/raycast-utils.cjs").utilitiesFor(() => require("/{adapter}.cjs"));\n'
            )
            if phase != "noview":
                react = root / "node_modules" / "react"
                react.mkdir()
                (react / "index.js").write_text('const api = require("/view-api.cjs"); exports.useState = api.useState; exports.useEffect = api.useEffect; exports.useRef = api.useRef; exports.useId = api.useId;\n')
                (react / "jsx-runtime.js").write_text('module.exports = require("/view-api.cjs").jsxRuntime;\n')
        else:
            shutil.copyfile(source, root / "sample.cjs")
            (root / "sample.cjs").chmod(0o444)
        marker = "build" if phase in ("uuid-build", "view-build", "uuid-suite-build", "menu-bar-build") else phase
        (root / f"{marker}-only").write_text(marker)

    entries = sorted(str(path.relative_to(root)) for path in root.rglob("*"))
    with (output / f"{phase}.cpio").open("wb") as archive:
        subprocess.run(["cpio", "-o", "-H", "newc"], cwd=root, input="\n".join(entries).encode() + b"\n",
                       stdout=archive, check=True)


if __name__ == "__main__":
    asset_manifest = None
    if len(sys.argv) == 7 and sys.argv[5] == "--assets-manifest":
        if sys.argv[3] not in ("noview", "view", "uuid-suite", "menu-bar"):
            raise SystemExit("reviewed assets require a runtime artifact")
        asset_manifest = Path(sys.argv[6]).resolve(strict=True)
        del sys.argv[5:]
    if len(sys.argv) not in (4, 5) or sys.argv[3] not in ("probe", "build", "run", "uuid-build", "noview", "view-build", "view", "uuid-suite-build", "uuid-suite", "menu-bar-build", "menu-bar"):
        raise SystemExit("usage: prepare.py kernel.apk output-directory phase [sample [--assets-manifest manifest.json]]")
    apk, output = (Path(argument).resolve() for argument in sys.argv[1:3])
    phase = sys.argv[3]
    source = Path(sys.argv[4]).resolve(strict=True) if len(sys.argv) == 5 else None
    if (phase in ("run", "uuid-build", "noview", "view-build", "view", "uuid-suite-build", "uuid-suite", "menu-bar-build", "menu-bar")) != (source is not None):
        raise SystemExit("expected a reviewed source or artifact for this phase")
    with tempfile.TemporaryDirectory(prefix="initramfs-", dir=output) as directory:
        prepare(apk, output, Path(directory), phase, source, asset_manifest)
