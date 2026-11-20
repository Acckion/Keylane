#!/bin/bash
# Controlled fixture ONLY. Optional stage builds/runs only the self-authored fixture in guest VMs.
set -euo pipefail
[[ $# == 2 || $# == 3 ]] || { echo 'usage: verify-vm.sh pinned-cache scratch-directory' >&2; exit 2; }
identity=${KEYLANE_VM_SIGN_IDENTITY:?Set the existing Apple Development signing identity}
[[ "$identity" != '-' && "$identity" == Apple\ Development* ]] || { echo 'Apple Development identity required' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd -P)
mkdir -p "$2"
scratch=$(cd "$2" && pwd -P)
app="$scratch/StoreIngressFixture.app"
[[ ! -e "$app" ]] || { echo 'Choose fresh scratch directory; refusing to overwrite test bundle' >&2; exit 2; }
python3 "$here/prepare-fixture.py" "$1" "$scratch" "${3:-ingress}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/IngressFixtureHost.swift" "$scratch/main.swift"
xcrun swiftc -swift-version 5 "$here/../../../Sources/KeylaneCore/StoreRuntimeBridge.swift" "$here/../../../Sources/KeylaneCore/StoreSignedGuestEngine.swift" -module-cache-path "$scratch/swift-cache" "$here/../../../Sources/KeylaneCore/ExtensionPrototypeSession.swift" "$here/../../../Sources/KeylaneCore/ExtensionClipboardContent.swift" "$scratch/main.swift" -o "$app/Contents/MacOS/StoreIngressFixture"
[[ ! -f "$scratch/real-api" ]] || cp "$scratch/real-api" "$app/Contents/Resources/"
cp "$scratch/Image" "$scratch/ingress.cpio" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>site.keylane.store-ingress-fixture</string><key>CFBundleExecutable</key><string>StoreIngressFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cat > "$scratch/entitlements.plist" <<'PLIST'
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
codesign --force --sign "$identity" --timestamp=none --options runtime --entitlements "$scratch/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
if [[ "${3:-ingress}" == stage || "${3:-ingress}" == real ]]; then
 "$app/Contents/MacOS/StoreIngressFixture" build > "$scratch/build.log" 2>&1
 grep -q 'fixture=passed vmStopped=true' "$scratch/build.log"
 sed -n 's/^ARTIFACT://p' "$scratch/build.log" > "$scratch/artifact.json"
 digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$scratch/artifact.json")
 # A new process creates a NEW signed VM with no shared guest filesystem or memory.
 "$app/Contents/MacOS/StoreIngressFixture" run "$scratch/artifact.json" "$digest" > "$scratch/run.log" 2>&1
 grep -q 'fixture=passed vmStopped=true' "$scratch/run.log"
 codesign --verify --deep --strict "$app"
 "$app/Contents/MacOS/StoreIngressFixture" recipe-reject > "$scratch/recipe-reject.log" 2>&1
 grep -q 'fixture=passed vmStopped=true' "$scratch/recipe-reject.log"
 # Wrong digest is rejected by the host as DATA before VM construction.
 python3 - "$scratch/artifact.json" "$scratch/tampered.json" <<'PYTEST'
import json,sys
v=json.load(open(sys.argv[1]));v['sha256']='0'*64
with open(sys.argv[2],'w') as out: json.dump(v,out)
PYTEST
 if "$app/Contents/MacOS/StoreIngressFixture" run "$scratch/tampered.json" "$digest" > "$scratch/tampered.log" 2>&1; then exit 1; fi
 grep -q 'artifact digest' "$scratch/tampered.log"
 if [[ "${3:-ingress}" == real ]]; then
  grep -q 'real-host-toast-received=true' "$scratch/run.log"
  team=$(codesign -d --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$team" =~ ^[A-Z0-9]+$ ]]
  "$app/Contents/MacOS/StoreIngressFixture" bridge "$team" > "$scratch/bridge.log" 2>&1
  grep -q 'typed bridge built and ran digest=' "$scratch/bridge.log"
  grep -q 'real-host-toast-received=true' "$scratch/bridge.log"
  [[ $(grep -c 'fixture=passed vmStopped=true' "$scratch/bridge.log") == 2 ]]
  if "$app/Contents/MacOS/StoreIngressFixture" bridge-timeout "$team" > "$scratch/bridge-timeout.log" 2>&1; then exit 1; fi
  grep -q 'fixture deadline exceeded' "$scratch/bridge-timeout.log"
  grep -q 'fixture=failed vmStopped=true' "$scratch/bridge-timeout.log"
 fi
 python3 - "$scratch/artifact.json" "$scratch/stale.json" <<'PYTEST'
import json,sys
v=json.load(open(sys.argv[1]));v['provenance']['installationGeneration']=2
with open(sys.argv[2],'w') as out: json.dump(v,out)
PYTEST
 if "$app/Contents/MacOS/StoreIngressFixture" run "$scratch/stale.json" "$digest" > "$scratch/stale.log" 2>&1; then exit 1; fi
 grep -q 'artifact provenance' "$scratch/stale.log"
 bash "$here/verify-provenance.sh" "$app/Contents/MacOS/StoreIngressFixture" "$scratch/artifact.json" "$scratch" "$digest"
 echo 'recipe, artifact-digest and provenance-generation rejection: passed'
 echo "fixed source → guest esbuild → bounded artifact → fresh guest execution: passed (mode=${3})"
 exit 0
fi
for mode in valid oversize replay corrupt; do
 "$app/Contents/MacOS/StoreIngressFixture" "$mode" > "$scratch/$mode.log" 2>&1
 grep -q 'fixture=passed vmStopped=true' "$scratch/$mode.log"
 echo "$mode: passed; VM stopped"
done
codesign --verify --deep --strict "$app"
