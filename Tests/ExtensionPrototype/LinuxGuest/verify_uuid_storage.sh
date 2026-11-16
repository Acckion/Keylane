#!/bin/bash
# Uses the helper from verify.sh, the pinned upstream source files and icu-data-en.apk.
set -euo pipefail
test "$#" -eq 2 || { echo "usage: verify_uuid_storage.sh scratch-directory reviewed-source-directory" >&2; exit 2; }
scratch=$(cd "$1" && pwd -P)
source=$(cd "$2" && pwd -P)
here=$(cd "$(dirname "$0")" && pwd -P)
sentinel=$(mktemp "$scratch/uuid-storage-host-sentinel.XXXXXX")
trap 'rm -f "$sentinel"' EXIT

python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" uuid-suite-build "$source"
"$scratch/host" "$scratch/Image" "$scratch/uuid-suite-build.cpio" "$sentinel" uuid-suite-build - \
    > "$scratch/uuid-suite-build.out" 2> "$scratch/uuid-suite-build.log"
sed -n 's/^guest-result=//p' "$scratch/uuid-suite-build.out" | base64 -D | gzip -dc > "$scratch/uuid-suite.cjs"
python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" uuid-suite "$scratch/uuid-suite.cjs"

run_guest() {
    "$scratch/host" "$scratch/Image" "$scratch/uuid-suite.cpio" "$sentinel" uuid-storage-app - \
        < "$scratch/uuid-$1.request" > "$scratch/uuid-$1.out" 2> "$scratch/uuid-$1.log"
    sed -n 's/^guest-result=//p' "$scratch/uuid-$1.out" | base64 -D > "$scratch/uuid-$1.json"
    grep -q '^guest probe passed, .*state=0' "$scratch/uuid-$1.out"
}

printf '%s' '{"mode":"generate","count":20,"preferences":{"defaultAction":"copy","upperCaseLetters":true},"storage":{}}' \
    > "$scratch/uuid-generate.request"
run_guest generate
python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys
from uuid import UUID

folder = Path(sys.argv[1])
result = json.loads((folder / "uuid-generate.json").read_text())
assert result["kind"] == "copy"
generated = result["text"].splitlines()
assert len(generated) == 20 and all(value == value.upper() and UUID(value).version == 4 for value in generated)
assert [entry["uuid"] for entry in json.loads(result["storage"]["uuidHistory"])] == generated
base = {"mode": "history", "preferences": {"defaultAction": "copy"}, "storage": result["storage"]}
(folder / "uuid-history.request").write_text(json.dumps(base))
for name, index in [("copy", 0), ("delete", 2), ("clear", 3)]:
    request = base | {"action": {"row": 0, "id": index}, "confirmed": name == "clear"}
    (folder / f"uuid-{name}.request").write_text(json.dumps(request))
PY
for mode in history copy delete clear; do run_guest "$mode"; done
python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1])

def result(name):
    return json.loads((folder / f"uuid-{name}.json").read_text())

generated = result("generate")["text"].splitlines()
assert [row["title"] for row in result("history")["rows"]] == generated[::-1]
assert result("copy") == {"kind": "copy", "text": generated[-1]}
assert [entry["uuid"] for entry in json.loads(result("delete")["storage"]["uuidHistory"])] == generated[:-1]
assert result("clear") == {"kind": "storage", "storage": {}}
print("PASS isolated UUID generation and LocalStorage history, copy, delete and clear")
PY

python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys
from uuid import NAMESPACE_DNS

folder = Path(sys.argv[1])
namespace = str(NAMESPACE_DNS)
fixtures = {
    "v5": ("generateV5", {"name": "keylane.example", "numberOfUUIDsToGenerate": "2"}, {"uuidNamespace": namespace}),
    "v5-invalid": ("generateV5", {"name": "keylane.example"}, {"uuidNamespace": ""}),
    "v7": ("generateV7", {"numberOfUUIDsToGenerate": "2"}, {}),
    "v7-base32": ("generateV7", {}, {"base32Encoding": True}),
    "ulid": ("generateUlid", {"numberOfULIDsToGenerate": "2"}, {}),
    "typeid": ("generateTypeID", {"prefix": "keylane_test"}, {}),
    "pack": ("packTypeID", {"suffix": "doctor", "uuid": "0195b514-74a3-7250-b9bb-70e07500ed8b"}, {}),
    "parse": ("parseTypeID", {"typeID": "doctor_01jpth8x53e98bkevgw1tg1vcb"}, {"defaultAction": "paste"}),
    "parse-invalid": ("parseTypeID", {"typeID": "invalid"}, {}),
    "pack-invalid": ("packTypeID", {"suffix": "doctor", "uuid": "invalid"}, {}),
}
for name, (mode, args, options) in fixtures.items():
    request = {
        "mode": mode, "arguments": args, "storage": {},
        "preferences": {"defaultAction": "copy", **options},
    }
    (folder / f"uuid-{name}.request").write_text(json.dumps(request))
PY
for mode in v5 v5-invalid v7 v7-base32 ulid typeid pack parse parse-invalid pack-invalid; do run_guest "$mode"; done
python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import re
import sys
from uuid import UUID, NAMESPACE_DNS, uuid5

folder = Path(sys.argv[1])

def result(name):
    return json.loads((folder / f"uuid-{name}.json").read_text())

def generated(name, kind, count):
    reply = result(name)
    assert reply["kind"] == "copy"
    lines = reply["text"].splitlines()
    records = json.loads(reply["storage"]["uuidHistory"])
    assert len(lines) == count and [record["uuid"] for record in records] == lines
    assert all(record["type"] == kind for record in records)
    return lines, records

v5, v5_records = generated("v5", "uuidV5", 2)
assert v5 == [str(uuid5(NAMESPACE_DNS, "keylane.example"))] * 2
v7, v7_records = generated("v7", "uuidV7", 2)
assert all(UUID(value).version == 7 for value in v7)
base32, base32_records = generated("v7-base32", "uuidV7", 1)
assert re.fullmatch("[0-7][0-9a-hjkmnp-tv-z]{25}", base32[0])
ulids, ulid_records = generated("ulid", "ulid", 2)
assert ulids[0] < ulids[1] and all(re.fullmatch("[0-7][0-9A-HJKMNP-TV-Z]{25}", value) for value in ulids)
typeids, typeid_records = generated("typeid", "typeid", 1)
assert re.fullmatch("keylane_test_[0-7][0-9a-hjkmnp-tv-z]{25}", typeids[0])
assert result("pack") == {"kind": "copy", "text": "doctor_01jpth8x53e98bkevgw1tg1vcb"}
assert result("parse") == {"kind": "paste", "text": "0195b514-74a3-7250-b9bb-70e07500ed8b"}
for name, message in [("v5-invalid", "Invalid namespace"), ("parse-invalid", "Decoding Error"), ("pack-invalid", "Error generating packed type ID")]:
    reply = result(name)
    assert reply["kind"] == "error" and message in reply["text"] and "storage" not in reply
records = v5_records + v7_records + base32_records + ulid_records + typeid_records
(folder / "uuid-mixed-history.request").write_text(json.dumps({
    "mode": "history", "storage": {"uuidHistory": json.dumps(records)},
    "preferences": {"defaultAction": "copy"},
}))
print("PASS isolated V5, V7, Base32 V7, ULID, TypeID generation, TypeID pack/parse and upstream failures")
PY
run_guest mixed-history
python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1])
request = json.loads((folder / "uuid-mixed-history.request").read_text())
result = json.loads((folder / "uuid-mixed-history.json").read_text())
records = json.loads(request["storage"]["uuidHistory"])
assert [row["title"] for row in result["rows"]] == [record["uuid"] for record in reversed(records)]
print("PASS mixed generated types appear in history, including repeated V5 results")
PY
