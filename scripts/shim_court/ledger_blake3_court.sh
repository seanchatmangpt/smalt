#!/usr/bin/env bash
# ledger-blake3 shim court (lane 11, v26.11.6 BLAKE3 chain-link retarget).
#
# Proves the retargeted gate's gen-2 link re-derivation is NON-VACUOUS:
#   BASELINE sha256 the gate; BEFORE intact gate ACCEPTS a healthy gen-2
#   chain fixture (built with the gate's own law); SHIM folds the HEX TEXT
#   of prev/data_hash instead of raw32 bytes into the re-derivation
#   (SHIM-COURT marker); AFTER shimmed gate REFUSES the healthy chain with
#   "merkle_root re-derivation mismatch" -- the flip is the proof; RESTORE
#   sha256 byte-exact, fail-closed.
#
# Usage: just shim-court ledger-blake3
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

GATE="$ROOT/gates/ledger_chain_gate.py"
[ -f "$GATE" ] || shim_court_skip "gate subject not found: $GATE"
REF="$ROOT/gates/blake3_ref.py"
[ -f "$REF" ] || shim_court_skip "blake3_ref not found: $REF"

shim_court_self_check || shim_court_fail BEFORE \
    "sha256 restore-detection self-check failed (harness vacuous)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/ledger_fixture.json"

# --- Build the real gen-2 chain fixture with the gate's own law ---------------
SHIM_FIXTURE="$FIXTURE" python3 - <<'PYEOF'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("gate", "gates/ledger_chain_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

prev = gate.ZERO_HASH
listed = []
for i, e in enumerate([{"k": "court-a"}, {"k": "court-b"}, {"k": "court-c"}], 1):
    dh = gate.data_hash(e)
    root = gate.link_digest(prev, i, dh, "default_ledger")
    listed.append({"transactionId": f"{i}.1", "subLedgerId": "default_ledger",
                   "chain_gen": 2, "contents": e, "data_hash": dh,
                   "prev_hash": prev, "merkle_root": root})
    prev = root
dh = gate.data_hash({"k": "court-a"})
root = gate.link_digest(prev, 4, dh, "default_ledger")
dup = {"transactionId": "4.1", "subLedgerId": "default_ledger",
       "chain_gen": 2, "contents": {"k": "court-a"}, "data_hash": dh,
       "prev_hash": prev, "merkle_root": root}
obs = {"ledger": "default_ledger", "appends": [201, 201, 201],
       "receipts": listed, "dup_status": 201, "dup_receipt": dup,
       "fetch_statuses": [200] * 4, "listed": listed + [dup],
       "latest_status": 200, "latest": {"transactionId": "4.1"}}
json.dump(obs, open(os.environ["SHIM_FIXTURE"], "w"), indent=2, sort_keys=True)
PYEOF
[ -f "$FIXTURE" ] || shim_court_fail BASELINE "fixture builder produced no fixture"
shim_court_log COURT "subject: real 4-link gen-2 chain fixture @ $FIXTURE (law from gates/ledger_chain_gate.py + blake3_ref.py)"

# --- Witness helper (real collaborator: the gate module itself) ---------------
WITNESS="$WORK/witness.py"
cat > "$WITNESS" <<'PYEOF'
import importlib.util, json, os, sys
fix, expect, need = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
spec = importlib.util.spec_from_file_location("gate", "gates/ledger_chain_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
obs = json.load(open(fix))
ok, details = gate.verdict(obs)
detail_str = "; ".join(details)
if expect == "accept":
    if not ok:
        sys.exit(1)
else:
    if ok:
        print("[witness] expected REFUSE, gate ACCEPTED (vacuous)", file=sys.stderr)
        sys.exit(1)
    if need and need not in detail_str:
        print(f"[witness] refused but {need!r} absent", file=sys.stderr)
        sys.exit(1)
PYEOF

# Also verify the seq-not-in-digest forgery is refused BEFORE the shim
# (the mutant-killing fixtures themselves must hold).
FORGED="$WORK/forged.json"
cp "$FIXTURE" "$FORGED"
SHIM_FORGED="$FORGED" python3 - <<'PYEOF2'
import importlib.util, json, os, sys
sys.path.insert(0, "gates")
import blake3_ref
spec = importlib.util.spec_from_file_location("gate", "gates/ledger_chain_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
obs = json.load(open(os.environ["SHIM_FORGED"]))
prev = gate.ZERO_HASH
for r in obs["listed"]:
    dh_raw = bytes.fromhex(r.get("data_hash", ""))
    prev_raw = bytes.fromhex(prev)
    no_seq = blake3_ref.blake3_hex(
        gate.LINK_DOMAIN.encode() + prev_raw + dh_raw
        + r.get("subLedgerId", "").encode())
    r["merkle_root"] = no_seq
    r["prev_hash"] = prev
    prev = no_seq
json.dump(obs, open(os.environ["SHIM_FORGED"], "w"), indent=2, sort_keys=True)
PYEOF2
[ -f "$FORGED" ] || shim_court_fail BEFORE "forged fixture builder produced no fixture"

# --- with_shim: BASELINE -> BEFORE -> SHIM -> AFTER -> RESTORE ----------------
apply_shim() {
  # Fold the HEX TEXT of prev/data_hash instead of raw32 bytes into the
  # gate's gen-2 re-derivation (the canonical hex-fold mutant class).
  SHIM_GATETEXT="$GATE" python3 - <<'PYEOF3'
import os
p = os.environ["SHIM_GATETEXT"]
src = open(p).read()
old = """        LINK_DOMAIN.encode() + prev_raw + seq.to_bytes(8, "big") + dh_raw
        + sub_ledger_id.encode())"""
new = """        LINK_DOMAIN.encode() + prev_root_hex.encode() + seq.to_bytes(8, "big") + data_hash_hex.encode()  # SHIM-COURT: hex-fold instead of raw32
        + sub_ledger_id.encode())"""
assert old in src, "gate link law line not found"
open(p, "w").write(src.replace(old, new))
PYEOF3
}

BEFORE_CMDS="python3 $WITNESS $FIXTURE accept && python3 $WITNESS $FORGED refuse"
AFTER_CMD="python3 $WITNESS $FIXTURE refuse 'merkle_root re-derivation mismatch'"

with_shim "$GATE" "$BEFORE_CMDS" "$AFTER_CMD"
