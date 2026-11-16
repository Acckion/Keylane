#!/bin/bash
# Uses the signed helper from verify.sh and the pinned Work Time Countdown sources.
set -euo pipefail
test "$#" -eq 2 || { echo "usage: verify_menu_bar.sh scratch-directory reviewed-source-directory" >&2; exit 2; }
scratch=$(cd "$1" && pwd -P)
source=$(cd "$2" && pwd -P)
here=$(cd "$(dirname "$0")" && pwd -P)
sentinel=$(mktemp "$scratch/menu-bar-host-sentinel.XXXXXX")
trap 'rm -f "$sentinel"' EXIT
python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" menu-bar-build "$source"
"$scratch/host" "$scratch/Image" "$scratch/menu-bar-build.cpio" "$sentinel" menu-bar-build - \
    > "$scratch/menu-bar-build.out" 2> "$scratch/menu-bar-build.log"
sed -n 's/^guest-result=//p' "$scratch/menu-bar-build.out" | base64 -D > "$scratch/menu-bar.cjs"
python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" menu-bar "$scratch/menu-bar.cjs"
python3 - "$scratch" <<'PY'
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1])
scenarios = [
    ("working", "2026-11-12T18:30", False, None),
    ("one-minute-later", "2026-11-12T18:31", False, None),
    ("after-hours", "2026-11-12T20:00", False, None),
    ("weekend", "2026-11-14T18:30", False, None),
    ("weekend-enabled", "2026-11-14T18:30", True, None),
    ("configure", "2026-11-12T18:30", False, 0),
]
for name, time, weekends, action in scenarios:
    request = {
        "mode": "menuBar",
        "preferences": {"startHour": "9", "endHour": "19", "includeWeekends": weekends},
        "wallTime": datetime.fromisoformat(time).replace(tzinfo=timezone.utc).timestamp() * 1000,
    }
    if action is not None:
        request["menuAction"] = action
    (folder / f"menu-bar-{name}.request").write_text(json.dumps(request))
PY
for scenario in working one-minute-later after-hours weekend weekend-enabled configure; do
    prefix="$scratch/menu-bar-$scenario"
    "$scratch/host" "$scratch/Image" "$scratch/menu-bar.cpio" "$sentinel" view-app - \
        < "$prefix.request" > "$prefix.out" 2> "$prefix.log"
    sed -n 's/^guest-result=//p' "$prefix.out" | base64 -D > "$prefix.json"
    grep -q '^guest probe passed, .*state=0' "$prefix.out"
done
python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1])

def result(name):
    return json.loads((folder / f"menu-bar-{name}.json").read_text())

working = result("working")
assert working["visible"] and working["title"] == "30m"
assert working["icon"] == "Clock" and working["tint"] == "raycast-red" and working["subtitle"].endswith("95%")
assert working["items"] == [
    {"kind": "item", "id": 0, "title": "Configure Command", "enabled": True, "key": ",", "modifiers": ["cmd"]}
]
assert result("one-minute-later")["title"] == "29m"
assert not result("after-hours")["visible"] and not result("weekend")["visible"]
assert result("weekend-enabled")["visible"]
assert result("configure") == {"kind": "openPreferences"}
print("PASS Work Time Countdown isolated menu snapshot, time updates, schedule and preferences action")
PY
