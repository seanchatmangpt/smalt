#!/usr/bin/env bash
# fallthrough_halt_court.sh — non-vacuity court for the w6r_fallthrough
# send-halt fix in lib/smalt/egress_router.ex (lane W2-6).
#
# Witnessed defect: a w6R sub-router (CosmosRoutes) that SENT a response did
# not halt the chain; the conn fell through to the blob splat and blob_route's
# put_resp_header raised AlreadySentError (wire_norm kd07, lane E1 2026-10-20).
#
# Protocol (scripts/shim_court/lib.sh):
#   BEFORE  unmodified router: GET /dbs/.../docs is sent exactly once,
#           state=:sent, no exception escapes EgressRouter.call.
#   SHIM    TEMP COPY of egress_router.ex with the `conn.state in
#           [:sent, :chunked] -> Plug.Conn.halt(conn)` arm DROPPED (marker
#           SHIM-COURT). lib/smalt/egress_router.ex itself is never touched;
#           the temp copy is baselined and restored sha256 byte-exact.
#   AFTER   shimmed router: Plug.Conn.AlreadySentError escapes
#           EgressRouter.call — the flip proves the fix is non-vacuous.
#
# Exit 0 PASS / 1 FAIL / 3 loud SKIP.

set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/shim_court/lib.sh

# Non-vacuity of the restore rule itself (real temp-copy proof, per court run).
shim_court_self_check || shim_court_fail SHIM "self-check failed"

# --- Environment gates (loud SKIP, never a faked pass) ----------------------
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"

SUBJECT="lib/smalt/egress_router.ex"
HALT_ARM='conn.state in [:sent, :chunked]'

if ! grep -qF "$HALT_ARM" "$SUBJECT"; then
    shim_court_skip "subject $SUBJECT no longer carries the halt arm being proven; court shim is stale"
fi

# --- Shim: drop the halt arm on a TEMP COPY --------------------------------
SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shim_court.fallthrough.XXXXXX")"
SHIM_COPY="$SHIM_DIR/egress_router.ex"
cp "$SUBJECT" "$SHIM_COPY"

apply_shim() {
    # SHIM-COURT: remove the [:sent, :chunked] halt arm so a sub-router that
    # SENT falls through to the blob splat — reproducing the witnessed defect.
    python3 - "$SHIM_COPY" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
arm = "        conn.state in [:sent, :chunked] ->\n          Plug.Conn.halt(conn)\n"
if arm not in src:
    sys.exit("SHIM-COURT: halt arm not found in temp copy")
src = src.replace(arm, "        # SHIM-COURT: halt arm dropped; sent conns fall through\n")
with open(path, "w") as f:
    f.write(src)
PY
}

BEFORE_CMD='mix run --no-start scripts/shim_court/fallthrough_halt_witness.exs before'
AFTER_CMD='SHIM_SRC="'"$SHIM_COPY"'" mix run --no-start scripts/shim_court/fallthrough_halt_witness.exs after'

cleanup() {
    rm -rf "$SHIM_DIR"
}
trap cleanup EXIT

with_shim "$SHIM_COPY" "$BEFORE_CMD" "$AFTER_CMD"
