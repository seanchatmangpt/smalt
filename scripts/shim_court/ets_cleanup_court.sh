#!/usr/bin/env bash
# ets_cleanup_court.sh — shim court proving R189's ETS cleanups non-vacuous (v26.10.16).
#
# Subjects: test/mcp_test.exs, test/mcp_wire_test.exs, test/smalt_arm_gateway_test.exs
# — the R178g/R189 on_exit cleanup registrations that delete the seeded store
# keys (:smalt_resources / :smalt_blobs / :smalt_vault_keys) so they never leak
# into other suites sharing the tables.
#
# Leak mechanism: the seeded rows are read-tool fixtures; nothing else deletes
# them. With the on_exit registrations neutralized to :ok, the keys remain LIVE
# in the shared ETS after the suite drains.
#
# Ordering law (inherited from strata_cleanup_court.sh, 2026-10-16 MEASURED):
# ExUnit cross-module order is load-arrival order, uncontrollable via --seed
# across FILES — but same-file module registration is sequential and --seed 0
# pins definition order. So the leak witness is APPENDED as a second module in
# one shimmed file (test/mcp_wire_test.exs, the with_shim host): it necessarily
# runs after Smalt.McpWireTest's own shimmed setup left its keys live. The
# other two shimmed files widen the leak but the witness measures only the
# guaranteed same-file leak chain, keeping the flip deterministic.
#
# Protocol (scripts/shim_court/lib.sh with_shim, host = test/mcp_wire_test.exs):
#   BASELINE  sha256 of the host; the two auxiliary subjects are snapshotted
#             and sha256-baselined by shim_aux (fail-closed in AFTER + at the
#             end of the run, same byte-exact law).
#   BEFORE    `mix test <3 files>` green on pristine files (cleanups present,
#             no leak anywhere).
#   SHIM      apply_shim neutralizes the host's on_exit to :ok (marker
#             `# SHIM-COURT: R189 cleanup disabled`), appends
#             EtsCleanupLeakWitnessTest to the host, and neutralizes the two
#             auxiliary subjects' on_exit blocks with the same marker.
#   AFTER     the witness asserts the seeded key prefixes are EMPTY after the
#             suite; under the shim the keys are live, so the run is RED and
#             the failure message ENUMERATES the leaked keys
#             (`R189 LEAKED KEYS: ...`). Flip proof = nonzero mix exit AND
#             that receipt AND no compile error AND the auxiliary restores
#             verify byte-exact. An inert shim (cleanup still active) makes
#             the witness pass, the run goes green, and the court FAILs.
#   RESTORE   host sha256 byte-exact via lib.sh (fail-closed); auxiliary
#             subjects restored inside AFTER/teardown with the same sha law.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

HOST=test/mcp_wire_test.exs
AUX1=test/mcp_test.exs
AUX2=test/smalt_arm_gateway_test.exs
export MIX_BUILD_ROOT=_build-lane291   # lane-local build root, never the shared one

command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
for f in "$HOST" "$AUX1" "$AUX2"; do
    [ -f "$f" ] || shim_court_skip "subject missing: $f"
    grep -q 'on_exit(fn ->' "$f" || shim_court_skip "subject degraded: $f lacks an on_exit registration"
    grep -q 'EtsCleanupLeakWitnessTest' "$f" \
        && shim_court_skip "subject contaminated: $f already contains the appended witness module"
done

shim_court_self_check

# --- Auxiliary-subject shim/restore (outside lib.sh's single-file window) ---
AUX_BAK1="$(mktemp "${TMPDIR:-/tmp}/ets_court.aux1.XXXXXX")"
AUX_BAK2="$(mktemp "${TMPDIR:-/tmp}/ets_court.aux2.XXXXXX")"
AUX_SHA1=""
AUX_SHA2=""

shim_aux() {
    cp "$AUX1" "$AUX_BAK1"; cp "$AUX2" "$AUX_BAK2"
    AUX_SHA1="$(shim_court_sha "$AUX1")"
    AUX_SHA2="$(shim_court_sha "$AUX2")"
    SHIM_FILE="$AUX1" apply_shim || return 1
    SHIM_FILE="$AUX2" apply_shim || return 1
    grep -q 'SHIM-COURT' "$AUX1" && grep -q 'SHIM-COURT' "$AUX2" || return 1
}

restore_aux() {
    # Byte-exact restore of both auxiliary subjects, verified against the
    # baseline sha256 — same fail-closed law as lib.sh's RESTORE phase.
    cp "$AUX_BAK1" "$AUX1" && cp "$AUX_BAK2" "$AUX2" || return 1
    [ "$(shim_court_sha "$AUX1")" = "$AUX_SHA1" ] || return 1
    [ "$(shim_court_sha "$AUX2")" = "$AUX_SHA2" ] || return 1
}

trap 'restore_aux >/dev/null 2>&1 || printf "[FAIL:RESTORE] interrupt path: auxiliary restore did not verify\n" >&2' EXIT INT TERM

# AFTER_CMD runs via `bash -uc` (lib.sh) in a fresh shell: export the helper
# and its state so the auxiliary byte-exact restore is reachable there too.
export AUX1 AUX2 AUX_BAK1 AUX_BAK2 AUX_SHA1 AUX_SHA2
export -f restore_aux shim_court_sha

apply_shim() {
    # First call is for the HOST: snapshot + baseline the auxiliary subjects
    # before any edit, then neutralize them, then fall through to the host edit.
    if [ "$SHIM_FILE" = "$HOST" ]; then
        shim_aux || return 1
    fi
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, os, time
subject = sys.argv[1]
src = open(subject).read()

blocks = {
 "test/mcp_test.exs": '''    on_exit(fn ->
      {res, blob, key} = seeded

      for {table, k} <- [
            {:smalt_resources, res},
            {:smalt_blobs, blob},
            {:smalt_vault_keys, key}
          ] do
        if :ets.info(table) != :undefined, do: :ets.delete(table, k)
      end
    end)
''',
 "test/mcp_wire_test.exs": '''    on_exit(fn ->
      {res, blob} = seeded

      for {table, k} <- [{:smalt_resources, res}, {:smalt_blobs, blob}] do
        if :ets.info(table) != :undefined, do: :ets.delete(table, k)
      end
    end)
''',
 "test/smalt_arm_gateway_test.exs": '''    on_exit(fn ->
      if :ets.info(:smalt_resources) != :undefined do
        prefix = String.downcase("/subscriptions/#{@sub}/resourcegroups/rg-")

        for key <- Store.prefix_keys(:smalt_resources, prefix) do
          :ets.delete(:smalt_resources, key)
        end
      end
    end)
''',
}
neutralized = "    # SHIM-COURT: R189 cleanup disabled\n    :ok\n"

assert subject in blocks, f"unexpected shim subject {subject}"
old = blocks[subject]
n = src.count(old)
assert n == 1, f"{subject}: on_exit block expected exactly 1, got {n}"
src = src.replace(old, neutralized)

if subject == "test/mcp_wire_test.exs":
    src += '''
defmodule EtsCleanupLeakWitnessTest do
  # SHIM-COURT: R189 leak witness — appended by
  # scripts/shim_court/ets_cleanup_court.sh, removed by the byte-exact
  # RESTORE phase. Same-file module registration is sequential and --seed 0
  # pins definition order, so this runs AFTER Smalt.McpWireTest's shimmed
  # setup left its seeded keys live.
  use ExUnit.Case, async: false

  @default_sub "00000000-0000-0000-0000-000000000000"
  @mcp_res String.downcase(
             "/subscriptions/#{@default_sub}/resourcegroups/mcp-rg/providers/microsoft.storage/storageaccounts/mcpacct"
           )
  @mcp_blob "mcpacct/mcpcontainer/notes.txt"
  @mcp_key "mcp-key"

  test "R189: seeded key prefixes are EMPTY after the suite (cleanup present)" do
    if :ets.info(:smalt_resources) == :undefined do
      raise "table :smalt_resources missing — witness ran without the store up"
    end

    # Exact seeded keys from the shimmed setups…
    exact =
      for {table, k} <- [
            {:smalt_resources, @mcp_res},
            {:smalt_blobs, @mcp_blob},
            {:smalt_vault_keys, @mcp_key}
          ],
          :ets.info(table) != :undefined and :ets.member(table, k) do
        {table, k}
      end

    # …plus the whole rg- prefix family the gateway suite seeds.
    rg_prefix = String.downcase("/subscriptions/#{@default_sub}/resourcegroups/rg-")

    prefix =
      :smalt_resources
      |> Smalt.Store.prefix_keys(rg_prefix)
      |> Enum.map(&{:smalt_resources, &1})

    leaked = Enum.uniq(exact ++ prefix)

    leaked == [] or
      raise "R189 LEAKED KEYS: cleanup disabled left seeded rows live after the suite: #{inspect(leaked, limit: 10)}"
  end
end
'''

# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (witnessed in etag_cas_court).
os.utime(subject, (time.time() + 2, time.time() + 2))
open(subject, "w").write(src)
PYEOF
}

# BEFORE: pristine subjects — the combined suite is green (old signature
# holds: cleanups present, no leak anywhere).
BEFORE_CMD="cd $(pwd) && MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix test $HOST $AUX1 $AUX2 --seed 0 2>&1 | tail -4"

# AFTER: one real VM, --seed 0. Flip proof = the appended witness FAILS
# (nonzero mix exit) AND its failure message enumerates the leaked keys AND
# the run compiled. Then the auxiliary subjects are restored byte-exact
# (fail-closed) before reporting the flip.
AFTER_CMD="cd $(pwd) && LOG=\$(mktemp); MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix test $HOST --seed 0 >\"\$LOG\" 2>&1; ST=\$?; AUXOK=0; restore_aux || AUXOK=1; rm -f \"\$LOG.aux\"; if [ \$AUXOK -ne 0 ]; then echo '[FAIL:RESTORE] auxiliary subjects did not restore byte-exact'; exit 1; fi; if grep -q '== Compilation' \"\$LOG\"; then echo '[AFTER] compile error — cannot count as the flip'; tail -20 \"\$LOG\"; exit 1; fi; if [ \$ST -ne 0 ] && grep -q 'R189 LEAKED KEYS:' \"\$LOG\"; then echo '[AFTER] flip proven: neutralized on_exit cleanups left seeded rows live; the appended witness failed enumerating them'; grep -A2 'R189 LEAKED KEYS:' \"\$LOG\" | head -6; exit 0; else echo '[AFTER] flip NOT proven (mix exit '\$ST') — cleanup may still be active (shim inert):'; tail -8 \"\$LOG\"; exit 1; fi"

# Serialize concurrent court instances on the shared canonical checkout.
exec 9>/tmp/ets_cleanup_court.lock
flock 9

# with_shim drives BASELINE/BEFORE/SHIM/AFTER/RESTORE on the host file. The
# BEFORE witness runs the combined suite on pristine subjects; apply_shim
# snapshots + neutralizes the two auxiliary subjects alongside the host.
with_shim "$HOST" "$BEFORE_CMD" "$AFTER_CMD"

# Idempotent final aux restore + byte-exact verification. lib.sh's with_shim
# manages its own trap lifecycle (its AFTER-phase trap REPLACES ours and its
# failure path clears traps before exiting), so the aux subjects get their own
# explicit fail-closed restore here rather than relying on EXIT-trap ordering.
if ! restore_aux; then
    shim_court_fail RESTORE "auxiliary subjects did not restore byte-exact — CORRUPTED"
fi
printf '[SHIM] RESTORE verified byte-exact on aux subjects %s and %s (sha256 match)\n' \
    "$AUX1" "$AUX2"

rm -f "$AUX_BAK1" "$AUX_BAK2"
trap - EXIT INT TERM
