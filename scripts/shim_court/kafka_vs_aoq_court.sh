#!/usr/bin/env bash
# scripts/shim_court/kafka_vs_aoq_court.sh — L59 shim court (non-vacuity).
#
# Protocol: BASELINE (sha256) -> BEFORE (alloc fence holds) -> SHIM (per-op
# seeded binary:copy perturbation in BOTH legs' measured op paths, marker
# mandatory) -> AFTER (alloc fence MUST flip, else VACUOUS GATE exit 1) ->
# RESTORE (sha256 byte-exact, fail-closed).
#
# Subject: bench/kafka_vs_aoq_court.erl — the shim arms
# `_ = binary:copy(<<0:768>>)` inside kaf_send/2 and aoq_op/2 so every
# measured op allocates +768B caller-side and the <=128 B/op alloc fence
# must flip red. Runs the court's alloc-only face (alloc_mode/2 via
# tmp/l59_runner.exs L59_MODE=alloc).
#
# Run: just shim-court kafka_vs_aoq   (exit 0 = non-vacuous, 1 = FAIL,
#      3 = loud SKIP)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/shim_court/lib.sh" || true
TARGET="$REPO/bench/kafka_vs_aoq_court.erl"
LOG="$REPO/tmp/l59-alloc-probe.log"

command -v shasum >/dev/null 2>&1 || { echo "[SKIP] shasum not on PATH" >&2; exit 3; }
command -v mix >/dev/null 2>&1 || { echo "[SKIP] mix not on PATH" >&2; exit 3; }

sha() { shasum -a 256 "$TARGET" | awk '{print $1}'; }

run_alloc() {
  (cd "$REPO" && PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH" \
    L59_MODE=alloc MIX_ENV=test MIX_BUILD_ROOT=_build-lane59 \
    mix run --no-start --no-compile tmp/l59_runner.exs >/dev/null 2>"$LOG")
}

# -- BASELINE ----------------------------------------------------------------
BASE=$(sha)
echo "[kafka-vs-aoq] BASELINE $BASE"

# -- BEFORE: fence holds unshimmed -------------------------------------------
echo "[kafka-vs-aoq] BEFORE (alloc fence must hold)"
if ! run_alloc; then
  echo "BLOCKED(before): alloc probe failed unshimmed" >&2
  tail -20 "$LOG" >&2 || true
  exit 1
fi
grep -q "ALLOC PROBE PASS" "$LOG" || { echo "BLOCKED(before): kaf alloc fence not holding unshimmed" >&2; exit 1; }

# -- SHIM --------------------------------------------------------------------
cp "$TARGET" "$REPO/tmp/l59-shim-backup"
python3 - "$TARGET" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
assert "SHIM-COURT" not in s, "SHIM already armed"
marker = " %% SHIM-COURT: seeded binary:copy perturbation (non-vacuity falsifier)"
o1 = "    Batch = 'Elixir.Smalt.Messaging.Kafka.Records':encode_batch(\n              [#{key => nil, value => payload(), headers => []}]),"
n1 = "    _ = binary:copy(<<0:768>>)," + marker + "\n" + o1
assert o1 in s, "kaf_send site not found"
s = s.replace(o1, n1)
o2 = "    FrameBin = iolist_to_binary(frame_iolist(atomics:get(Seq, 1))),"
n2 = "    _ = binary:copy(<<0:768>>)," + marker + "\n" + o2
assert o2 in s, "aoq_op site not found"
s = s.replace(o2, n2)
open(p, "w").write(s)
PYEOF
if cmp -s "$TARGET" "$REPO/tmp/l59-shim-backup"; then echo "BLOCKED(shim): file unchanged" >&2; cp "$REPO/tmp/l59-shim-backup" "$TARGET"; exit 1; fi
echo "[kafka-vs-aoq] SHIM armed"

# -- AFTER: fence must flip ---------------------------------------------------
echo "[kafka-vs-aoq] AFTER (alloc fence must flip)"
AFTER_RC=0
run_alloc || AFTER_RC=$?
grep -q "ALLOC PROBE FLIPPED" "$LOG" || { echo "VACUOUS GATE: kaf alloc fence did not flip under the shim (rc=$AFTER_RC)" >&2; cp "$REPO/tmp/l59-shim-backup" "$TARGET"; exit 1; }

# -- RESTORE -----------------------------------------------------------------
cp "$REPO/tmp/l59-shim-backup" "$TARGET"
RESTORED=$(sha)
if [ "$RESTORED" != "$BASE" ] ; then
  echo "BLOCKED(restore): sha mismatch $BASE vs $RESTORED" >&2
  exit 1
fi
rm -f "$REPO/tmp/l59-shim-backup"
echo "[kafka-vs-aoq] RESTORE byte-exact ($RESTORED)"
echo "[kafka-vs-aoq] SHIM COURT PASS: fence flipped under shim, non-vacuous"
