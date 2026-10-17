#!/usr/bin/env bash
# ledger-chain shim court (mutate lane M3, v26.10.15 wave).
#
# Proves the ledger-chain invariant gate's Merkle link detection is
# NON-VACUOUS, without booting a substrate:
#
#   1. Build a REAL 3-link ledger chain fixture in a temp dir, using the
#      gate's own data_hash + merkle law (imported from
#      gates/ledger_chain_gate.py — real collaborator, no mocks).
#   2. BASELINE   sha256 of the fixture.
#   3. BEFORE     the real gate verdict() ACCEPTS the intact chain (old
#                 outcome: healthy ledger passes).
#   4. SHIM       apply_shim corrupts ONE chain link (receipt #2 prev_hash)
#                 in the temp fixture, tagging the corruption "SHIM-COURT".
#   5. AFTER      the real gate verdict() REFUSES the corrupted chain with
#                 the typed error "prev_hash does not link". This flip is
#                 the non-vacuity proof.
#   6. RESTORE    sha256 byte-exact, fail-closed.
#
# Self-check: corrupts a restore on a real temp copy to prove the sha256
# restore-detection rule itself is not vacuous (shim_court_self_check).
#
# Usage: just shim-court ledger-chain
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

GATE="$ROOT/gates/ledger_chain_gate.py"
[ -f "$GATE" ] || shim_court_skip "gate subject not found: $GATE"

shim_court_self_check || shim_court_fail BEFORE \
    "sha256 restore-detection self-check failed (harness vacuous)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/ledger_fixture.json"

# --- Build the real chain fixture with the gate's own law --------------------
SHIM_FIXTURE="$FIXTURE" python3 - <<'PYEOF'
import importlib.util, json, os

spec = importlib.util.spec_from_file_location(
    "ledger_gate", os.path.join(os.getcwd(), "gates", "ledger_chain_gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

import hashlib
prev = gate.ZERO_HASH
receipts = []
for i, entry in enumerate([{"k": "court-a"}, {"k": "court-b"}, {"k": "court-c"}], 1):
    dh = gate.data_hash(entry)
    root = hashlib.sha256((prev + dh).encode()).hexdigest()
    receipts.append({
        "transactionId": f"{i}.1",
        "contents": entry,
        "data_hash": dh,
        "prev_hash": prev,
        "merkle_root": root,
    })
    prev = root

obs = {
    "appends": [201, 201, 201],
    "receipts": receipts,
    "dup_status": 409,
    "list_status": 200,
    "listed": receipts,
}
with open(os.environ["SHIM_FIXTURE"], "w") as f:
    json.dump(obs, f, indent=2, sort_keys=True)
PYEOF
[ -f "$FIXTURE" ] || shim_court_fail BASELINE "fixture builder produced no fixture"

shim_court_log COURT "subject: real 3-link Merkle chain fixture @ $FIXTURE (law from gates/ledger_chain_gate.py)"

# --- Witness helper (real collaborator: the gate module itself) ---------------
WITNESS="$WORK/witness.py"
cat > "$WITNESS" <<'PYEOF'
import importlib.util, json, os, sys

fix, expect, need = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
spec = importlib.util.spec_from_file_location(
    "ledger_gate", os.path.join(os.getcwd(), "gates", "ledger_chain_gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

obs = json.load(open(fix))
ok, details = gate.verdict(obs)
detail_str = "; ".join(details)
if expect == "accept":
    if not ok:
        print(f"[witness] expected ACCEPT, gate refused: {detail_str}", file=sys.stderr)
        sys.exit(1)
else:
    if ok:
        print("[witness] expected REFUSE, gate accepted corrupted chain (VACUOUS GATE)",
              file=sys.stderr)
        sys.exit(1)
    if need and need not in detail_str:
        print(f"[witness] refused but typed error {need!r} absent from: {detail_str}",
              file=sys.stderr)
        sys.exit(1)
print(f"[witness] {expect} as expected: {detail_str}")
PYEOF

# --- with_shim: BASELINE -> BEFORE -> SHIM -> AFTER -> RESTORE ----------------
apply_shim() {
  # Corrupt ONE chain link: receipt #2's prev_hash no longer equals
  # receipt #1's merkle_root. Marker: "SHIM-COURT" key in the JSON body.
  SHIM_FIXTURE="$FIXTURE" python3 - <<'PYEOF'
import json, os
p = os.environ["SHIM_FIXTURE"]
obs = json.load(open(p))
assert len(obs["listed"]) >= 2, "fixture has no link #2 to corrupt"
obs["listed"][1]["prev_hash"] = "f" * 64   # SHIM-COURT: broken Merkle link
obs["listed"][1]["SHIM-COURT"] = True      # SHIM-COURT: marker required by lib.sh
with open(p, "w") as f:
    json.dump(obs, f, indent=2, sort_keys=True)
PYEOF
}

with_shim "$FIXTURE" \
  "python3 '$WITNESS' '$FIXTURE' accept" \
  "python3 '$WITNESS' '$FIXTURE' refuse 'prev_hash does not link'"
