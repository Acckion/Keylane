#!/bin/bash
# Uses the signed helper built by verify.sh, the two pinned upstream source files and icu-data-en.apk.
set -euo pipefail
test "$#" -eq 2 || { echo "usage: verify_view.sh scratch-directory reviewed-source-directory" >&2; exit 2; }
scratch=$(cd "$1" && pwd -P)
source=$(cd "$2" && pwd -P)
here=$(cd "$(dirname "$0")" && pwd -P)
sentinel=$(mktemp "$scratch/view-host-sentinel.XXXXXX")
trap 'rm -f "$sentinel"' EXIT
printf 'host-only-view-fixture\n' > "$sentinel"

python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" view-build "$source"
"$scratch/host" "$scratch/Image" "$scratch/view-build.cpio" "$sentinel" view-build - \
    > "$scratch/view-build.out" 2> "$scratch/view-build.log"
sed -n 's/^guest-result=//p' "$scratch/view-build.out" | base64 -D > "$scratch/chmod-view.cjs"
python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" view "$scratch/chmod-view.cjs"

run_view() {
    printf '%s' "$2" | "$scratch/host" "$scratch/Image" "$scratch/view.cpio" "$sentinel" view-app - \
        > "$scratch/$1.out" 2> "$scratch/$1.log"
    sed -n 's/^guest-result=//p' "$scratch/$1.out" | base64 -D > "$scratch/$1.json"
    grep -q '^guest probe passed, .*state=0' "$scratch/$1.out"
}
run_view view-examples '{"query":""}'
run_view view-conversion '{"query":"755"}'
run_view view-example-action '{"query":"","action":{"row":0,"id":0}}'
run_view view-copy-action '{"query":"755","action":{"row":0,"id":2}}'
run_view view-invalid '{"query":"invalid"}'

python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1])

def result(name):
    return json.loads((folder / f"view-{name}.json").read_text())

assert len(result("examples")["rows"]) == 8
conversion = result("conversion")["rows"][0]
assert "rwxr-xr-x" in conversion["markdown"]
assert {item["title"] for item in conversion["metadata"]} >= {"Owner", "Group", "Others"}
assert result("example-action") == {"kind": "query", "text": "755"}
assert result("copy-action") == {"kind": "copy", "text": "chmod 755"}
assert result("invalid")["rows"][0]["subtitle"] == "Not a valid mode"
print("PASS isolated CHMOD Lookup list, details, callback, copy payload, and invalid input")
PY
