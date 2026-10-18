# ATTEMPT-5 PATCH DRAFT — court-x2 warm-build legs (do not apply; coordinator applies at freeze)

Standing: DRAFT / UNAPPLIED. Subject: `scripts/court_x2.sh`, `justfile.d/24-quiesce.just`.

## Verification answer (asked by the lane)

**Does `scripts/court_x2.sh` set `MIX_BUILD_ROOT` today? No.** The single
occurrence is the OCEL emit call at line 74
(`MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build}" mix smalt.court_emit ...`), which
only defaults the variable for that one telemetry invocation. The two
`just court` legs (line 47) inherit the ambient environment, and the `court:`
recipe in `justfile` (line 201) sets no override. So the legs already compile
into the default `_build` — *unless* the operator's shell carries a lane
`MIX_BUILD_ROOT` (e.g. `_build-lane<N>`), in which case a court-x2 invoked from
a lane shell silently compiles a fresh cold root and pays the exact cold-compile
load face r240 attributed run-1 failures to.

## Chosen option: B — quiesce-warm warms the default root

Option A (court_x2.sh exporting `MIX_BUILD_ROOT=_build` for the legs) is a
pinning improvement but mechanically a no-op for the observed failure: the legs
already use `_build` in the clean-shell case, and the failure mode r240
witnessed (cold run 1) is caused by the warm-up compiling into a root that is
then **deleted**. Option B makes the warm-up populate the same build root the
legs consume, which is the only variant where the warm-up actually absorbs the
cold-compile cost.

Freshness-law argument: **compilation is not test state.** The legs still
execute every test, on every run, against the current `lib/` tree; mix's
`mix test` re-checks staleness and recompiles any source newer than its beam
before the suite runs. Reusing compile artifacts only removes *redundant*
compilation of identical inputs — no observation is reused, no test is skipped,
and any edit between quiesce and run 1 is recompiled by mix itself. The
"fresh runs, no reuse" law in court_x2.sh's header governs outcomes, not
bytewise re-derivation of `.beam` files; two greens on a warm shared root are
still two independent executions of the full suite.

Option B is also strictly additive: dropping the `rm -rf _build-warmup` removes
a lane-build-root-class leak (per same-checkout-fanout cleanup law — the
current recipe mints and abandons a build root per invocation), and removing
the override means `_build-lane<N>` shells running quiesce warm the lane root,
which is correct for a lane-local court-x2 too.

## Patch (unified diff)

```diff
--- a/justfile.d/24-quiesce.just
+++ b/justfile.d/24-quiesce.just
@@ -1,9 +1,10 @@
 # 24-quiesce — court precondition court (v26.10.17 lesson, receipts r240):
 # both court-x2 attempts failed their COLD run 1 on load faces and passed the
 # warm run 2. Encode the quiesce + warm-up discipline mechanically.
+# SHIM-COURT note: none — this is a justfile edit, not a shim; the AFTER flip
+# is `just quiesce` followed by a green court-x2 run 1 on a warm default root.
 
-# Verify the machine is quiet enough for a court run: no stray beams, court
-# ports free, no concurrent suites/courts. Exits 1 loudly on any violation.
+# Verify the machine is quiet enough for a court run: no stray beams, court
+# ports free, no concurrent suites/courts. Exits 1 loudly on any violation.
 @quiet-check:
     python3 scripts/quiet_check.py
 
-# Full quiesce before a court: quiet-check + a warm-up full offline suite that
-# absorbs cold-compile/profile noise, then quiet-check again. Run before
-# `just court-x2` when the machine has been busy.
+# Full quiesce before a court: quiet-check + a warm-up full offline suite that
+# absorbs cold-compile/profile noise, then quiet-check again. Run before
+# `just court-x2` when the machine has been busy. The warm-up compiles into
+# the DEFAULT build root (no MIX_BUILD_ROOT override) so run 1 of court-x2
+# starts from a warm root — compilation is reused, test execution is not.
 @quiesce: && quiesce-warm
     just quiet-check
 
 @quiesce-warm:
     #!/usr/bin/env bash
     set -euo pipefail
     echo "[QUIESCE] warm-up: full offline suite pass (absorbs cold run-1 load faces)"
-    MIX_BUILD_ROOT=_build-warmup mix test 2>&1 | tail -2
-    rm -rf _build-warmup
+    mix test 2>&1 | tail -2
     just quiet-check
     echo "[QUIESCE] machine settled — clear for court-x2"
```

(Note: the interleaved `# SHIM-COURT note` hunk above is documentation only;
a cleaner minimal diff is below for direct application.)

## Minimal diff (apply this one)

```diff
--- a/justfile.d/24-quiesce.just
+++ b/justfile.d/24-quiesce.just
@@ -13,7 +13,9 @@
-# Full quiesce before a court: quiet-check + a warm-up full offline suite that
-# absorbs cold-compile/profile noise, then quiet-check again. Run before
-# `just court-x2` when the machine has been busy.
+# Full quiesce before a court: quiet-check + a warm-up full offline suite that
+# absorbs cold-compile/profile noise, then quiet-check again. Run before
+# `just court-x2` when the machine has been busy. The warm-up compiles into
+# the DEFAULT build root (no MIX_BUILD_ROOT override) so court-x2 run 1 starts
+# warm — compilation is reused, test execution is never reused.
 @quiesce: && quiesce-warm
     just quiet-check
 
@@ -19,6 +21,5 @@
 @quiesce-warm:
     #!/usr/bin/env bash
     set -euo pipefail
     echo "[QUIESCE] warm-up: full offline suite pass (absorbs cold run-1 load faces)"
-    MIX_BUILD_ROOT=_build-warmup mix test 2>&1 | tail -2
-    rm -rf _build-warmup
+    mix test 2>&1 | tail -2
     just quiet-check
     echo "[QUIESCE] machine settled — clear for court-x2"
```

## Optional hardening (Option A, independent, one line)

Pin the legs against ambient lane roots so a court-x2 from a `_build-lane<N>`
shell cannot silently cold-compile:

```diff
--- a/scripts/court_x2.sh
+++ b/scripts/court_x2.sh
@@ -40,6 +40,9 @@
 overall=0
+
+# Court legs always compile into the default warm root. Compilation is not
+# test state — legs still execute every test fresh on every run.
+export MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build}"
 
 for run in 1 2; do
```

`"${MIX_BUILD_ROOT:-_build}"` deliberately *preserves* an explicitly exported
lane root (caller intent) while pinning the default — flip to a hard
`export MIX_BUILD_ROOT=_build` if the coordinator wants the legs pinned
unconditionally.

## Falsifier

`just quiesce && bash scripts/court_x2.sh` → run 1 must show 0 failures with a
warm `_build` (no `== Compilation error`, no cold-compile stall). If run 1
still fails on load faces with a warm default root, this patch does not close
r240 and must not flip any receipt.
