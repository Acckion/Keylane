#!/bin/bash
# Data-only mutations of a controlled fixture artifact, never host evaluation.
set -euo pipefail
[[ $# == 4 ]] || exit 2
host=$1
artifact=$2
scratch=$3
expected=$4
for key in sourceDigest recipe runtimeDigest installationID installationGeneration; do
 python3 - "$artifact" "$scratch/reject-$key.json" "$key" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]));key=sys.argv[3]
value['provenance'][key]=2 if key=='installationGeneration' else 'incorrect-fixture-context'
with open(sys.argv[2],'w') as output: json.dump(value,output)
PY
 if "$host" run "$scratch/reject-$key.json" "$expected" > "$scratch/reject-$key.log" 2>&1; then
  echo "Unexpectedly accepted changed $key" >&2; exit 1
 fi
 grep -q 'artifact provenance' "$scratch/reject-$key.log"
 if grep -q 'fixture socket accepted' "$scratch/reject-$key.log"; then exit 1; fi
 echo "$key mismatch rejected before VM start"
done
# Even an internally consistent replacement artifact cannot alter the trusted receipt.
python3 - "$artifact" "$scratch/replaced.json" <<'PYTEST'
import json,sys,base64,hashlib
value=json.load(open(sys.argv[1]));body=b'// replacement data; never executed'
value['artifact']=base64.b64encode(body).decode();value['sha256']=hashlib.sha256(body).hexdigest()
with open(sys.argv[2],'w') as output: json.dump(value,output)
PYTEST
if "$host" run "$scratch/replaced.json" "$expected" > "$scratch/replaced.log" 2>&1; then exit 1; fi
grep -q 'artifact receipt' "$scratch/replaced.log"
echo 'replacement artifact with recomputed hash rejected before VM start'
python3 - "$artifact" "$scratch/type-confused.json" <<'PYTEST'
import json,sys
value=json.load(open(sys.argv[1]));value['provenance']['installationGeneration']=True
with open(sys.argv[2],'w') as output: json.dump(value,output)
PYTEST
if "$host" run "$scratch/type-confused.json" "$expected" > "$scratch/type-confused.log" 2>&1; then exit 1; fi
grep -q 'artifact provenance' "$scratch/type-confused.log"
echo 'boolean/integer generation confusion rejected before VM start'
