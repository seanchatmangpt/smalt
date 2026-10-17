#!/usr/bin/env bash
# strata_cleanup_court.sh — shim court proving R178g's strata cleanup non-vacuous (v26.10.16).
#
# Subject: test/strata_compat_test.exs — the R178g disclosure in the strata
# store-pack CAS test: the success-path delete (`:ets.delete(:smalt_resources, "k")`)
# plus the on_exit failure-path cleanup that together keep the non-map probe row
# "k" (binary "v1"→"v2") out of the SHARED :smalt_resources table.
#
# Leak mechanism (why removal is observable): the whole-table `Smalt.Store.list/1`
# law asserts every returned value is a map (the churn suite's law,
# store_churn_test.exs:31). The "k" row holds a bare binary ("v2"), so once the
# cleanup is removed the leaked non-map row breaks the law in any same-VM
# whole-table walk that runs after the CAS test leaves it live.
#
# Ordering law (2026-10-16, MEASURED in this lane — three failed revisions):
# ExUnit's cross-module execution order is NOT controllable by --seed (it only
# shuffles WITHIN a case), is NOT reliably alphabetical, and is NOT the file-
# argument order (neutral three-probe experiment: neither CLI order nor
# module-name order; it is load-arrival order from the parallel compiler).
# async:true witnesses do not help either — ExUnit drains the ENTIRE async
# pool BEFORE starting the async:false queue, so a polling async witness runs
# to completion before the subject module ever starts (witnessed: 60s poll
# expired with the row never seeded). The construction that IS deterministic:
# append the witness as a SECOND MODULE in the same shimmed file — same-file
# registration is sequential, --seed 0 pins definition order across both
# modules, and the whole leak chain (CAS leaves "k" -> framing test touches
# nothing -> witness walks the real shared ETS) is measured stable 3/3.
# A compile error or a green-without-receipt run never counts as the flip.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(test/strata_compat_test.exs)
#   BEFORE    `mix test SUBJECT CHURN` green on the pristine file (cleanup
#             present => no leak anywhere).
#   SHIM      apply_shim comments out ONLY the success-path delete + on_exit
#             in the CAS test (marker `# SHIM-COURT: R178g cleanup removed`)
#             and APPENDS the StrataLeakWitnessTest module to the same file
#             (marked SHIM-COURT; it is the court's measuring instrument, not
#             a widening of the mutation).
#   AFTER     exit 0 AND `NONMAP leak reproduced` in the log AND no compile
#             error: the shimmed CAS test left "k" live and the appended
#             witness's whole-table walk observed it. An inert shim (cleanup
#             still active) makes the witness raise, the run goes red, and
#             the court FAILs.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

SUBJECT=test/strata_compat_test.exs
CHURN=test/store_churn_test.exs
export MIX_BUILD_ROOT=_build-lane227   # lane-local build root, never the shared one

# Loud skip when the environment cannot run the court for real.
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
[ -f "$SUBJECT" ] || shim_court_skip "subject missing: $SUBJECT"
[ -f "$CHURN" ] || shim_court_skip "churn witness missing: $CHURN"
grep -q 'R178g disclosure' "$SUBJECT" \
    || shim_court_skip "subject degraded: $SUBJECT lacks the R178g disclosure (cleanup already removed?)"
grep -q ':ets.delete(:smalt_resources, "k")' "$SUBJECT" \
    || shim_court_skip "subject degraded: success-path delete not present in $SUBJECT"
grep -q 'StrataLeakWitnessTest' "$SUBJECT" \
    && shim_court_skip "subject contaminated: $SUBJECT already contains the appended witness module"

shim_court_self_check

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, time
subject = sys.argv[1]
src = open(subject).read()

# 1) on_exit failure-path cleanup -> commented out.
on_exit_old = '''      on_exit(fn ->
        if :ets.info(:smalt_resources) != :undefined do
          :ets.delete(:smalt_resources, "k")
        end
      end)
'''
on_exit_new = '''      # SHIM-COURT: R178g cleanup removed
      # SHIM-COURT: R178g cleanup removed (on_exit failure-path delete)
      # SHIM-COURT: R178g cleanup removed (on_exit guard)
      # SHIM-COURT: R178g cleanup removed (end)
'''
assert src.count(on_exit_old) == 1, f"on_exit block: expected exactly 1, got {src.count(on_exit_old)}"

# 2) success-path delete -> commented out. (The on_exit copy is consumed by
#    the replacement above, leaving exactly one — the success-path line.)
src = src.replace(on_exit_old, on_exit_new)
delete_old = '      :ets.delete(:smalt_resources, "k")\n'
delete_new = '      # SHIM-COURT: R178g cleanup removed (success-path :ets.delete)\n'
assert src.count(delete_old) == 1, f"success-path delete: expected exactly 1, got {src.count(delete_old)}"
src = src.replace(delete_old, delete_new)

# 3) Append the witness module to the SAME file. Same-file registration is
#    sequential and --seed 0 pins definition order across both modules, so
#    this test runs AFTER the shimmed CAS test left "k" live and re-asserts
#    the churn whole-table is_map law on the real shared ETS.
src += '''
defmodule StrataLeakWitnessTest do
  # SHIM-COURT: R178g leak witness — appended by
  # scripts/shim_court/strata_cleanup_court.sh, removed by the byte-exact
  # RESTORE phase.
  use ExUnit.Case, async: false

  test "R178g: non-map row left LIVE in :smalt_resources when cleanup removed" do
    if :ets.info(:smalt_resources) == :undefined do
      raise "table :smalt_resources missing — witness ran without the store up"
    end

    values = Smalt.Store.list(:smalt_resources)
    leaked = Enum.filter(values, &(!is_map(&1)))

    leaked != [] or
      raise "R178g leak did NOT reproduce — cleanup still active (shim inert) or row vanished"

    IO.puts("SHIM-COURT: NONMAP leak reproduced: #{inspect(leaked, limit: 5)}")

    # Never leave the court's own probe row behind.
    :ets.delete(:smalt_resources, "k")
  end
end
'''
open(subject, "w").write(src)
# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (witnessed in etag_cas_court).
import os
os.utime(subject, (time.time() + 2, time.time() + 2))
PYEOF
}

# BEFORE: pristine subject — combined run is green (old signature holds:
# cleanup present, no leak anywhere; churn's own is_map law included).
BEFORE_CMD="cd $(pwd) && MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix test $SUBJECT $CHURN --seed 0 2>&1 | tail -4"

# AFTER: one real VM, --seed 0 (definition order: CAS is the last
# store-touching strata test; the appended witness module runs after it).
# Flip proof = exit 0 AND the witness's NONMAP receipt AND no compile error.
AFTER_CMD="cd $(pwd) && LOG=\$(mktemp); MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix test $SUBJECT --seed 0 >\"\$LOG\" 2>&1; ST=\$?; if grep -q 'Compilation error\|== Compilation' \"\$LOG\"; then echo '[AFTER] compile error — cannot count as the flip'; tail -15 \"\$LOG\"; exit 1; fi; if [ \$ST -eq 0 ] && grep -q 'NONMAP leak reproduced' \"\$LOG\"; then echo '[AFTER] flip proven: shimmed CAS test left the non-map row live in the shared table; the appended witness re-asserted the churn is_map law on the real shared ETS'; grep 'NONMAP leak reproduced' \"\$LOG\"; exit 0; else echo '[AFTER] flip NOT proven (exit '\$ST'):'; grep -E 'failure|Error|error' \"\$LOG\" | head -8; exit 1; fi"

# Serialize concurrent court instances: several lanes run this same court on
# the shared canonical checkout; overlapping with_shim windows on the subject
# sha-churned through 5 distinct values in 3 minutes (measured 03:51-03:55),
# racing BEFORE/AFTER/RESTORE against each other. Same-file lock fd, released
# at exit.
exec 9>/tmp/strata_cleanup_court.lock
flock 9

with_shim "$SUBJECT" "$BEFORE_CMD" "$AFTER_CMD"
