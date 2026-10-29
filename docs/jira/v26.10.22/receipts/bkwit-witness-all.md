# BK-WIT — witness-all rerun on the converged (post-repair) tree

Standing: PARTIAL_ALIVE (witness-all exit 1 by design on residual failures; every failure typed below — 24/40 REDs flipped green on single retry, zero unexplained)
Context: solo
Date: 20261022T0825Z

## Environment

Substrate UP (pid 76567, all four ports 9443/9444/5672/5673, lock FREE) — no boot needed.
Harness: `just witness-all` → `python3 scripts/witness_all.py` (receipt re-witness
gate over the two newest windows: v26.10.21 + v26.10.22). Full run ~2h wall
(first two attempts truncated by the 30-min background cap; third run completed).

## Verdict (verbatim)

```text
[WITNESS-SUMMARY] total=424 witnessed-green=128 stale-typed=232 failed=64
error: recipe `witness-all` failed on line 14 with exit code 1
```

- 232 stale-typed: every line carried a typed reason ("no command in a safe
  class (standing: …)" / "no rerunnable command in receipt") — zero silent
  skips in the stale class.
- 64 failed = 40 [WITNESS-RED] + 24 [WITNESS-FAIL] NO-STANDING.
- The 24 NO-STANDING are in-flight lanes' placeholder receipts (bkseal-full-green,
  bkrewit-wave1, bkwrap/bkwrap2, bksusp/bksusp2, bk4-fondrunner, bk7c, bkcens,
  bkisol, bkjar, bkkwt, erl4r, expl10, expl5/expl5r1/expl5r2, kafka-exp4,
  kd135-136-138-registrar, kd143, kd173r, kdconf, kdsasv, mcpt1) — in-flight-lane
  interference by construction (receipts not yet sealed with Standing). Not regressions.

## RED retry classification (single bounded retry, full logs /tmp/bkwit/retry_logs/)

24 of 40 REDs flipped green on retry — mid-edit compile/test interference from
concurrent lanes (sas_verifier / push_router / connection.ex / confidential_ledger
compile errors captured mid-edit; fresh `MIX_BUILD_ROOT=_build-witck mix compile`
now exits 0). Receipts: amqp10-court-closure, armfix-top3, bk134r, bk25, bk35,
bk41, bk45, bk47, bk80, bk94, gl12, gl3, gl5, gl7, gl8×2, glconf, gld3, gld5fix.

16 persistent, each typed:

| receipt | observed | class |
|---|---|---|
| bk27-kd86-90 | recorded command embeds prose (`→ 3/3 pass`); zsh refused | harness-extraction artifact (receipt fidelity) |
| bk106-sync-engine-fixes | kd_flip.py invoked with prose suffix `exit 0, FLIP-ELIGIBLE…` | harness-extraction artifact |
| bk115b-trip-regression | grep + `→ exit 1 (zero matches)` prose suffix | harness-extraction artifact |
| kddod-pointer-fence | `just docs-dod-check (tail)` prose suffix | harness-extraction artifact (docs-dod-check itself GREEN elsewhere in run) |
| kdmirror-canonical-sync | `just docs-dod-check -> exit 0…` prose suffix | harness-extraction artifact |
| ja10-transparency-court | recorded flag `--incl` → Mix "Unknown option. Did you mean --include?" | receipt-fidelity artifact (malformed recorded command) |
| expl9reg-row-mint | `grep -c "KD-COVERS: KD-174" lib/smalt/egress_router.ex` = 0 | stale-typed evidence — marker no longer present on tree (re-verified live during this lane) |
| bkbshape-phantom-options | `grep -c ifMatch …/RequestOptions.d.ts` = 0 | stale-typed evidence — node_modules version-dependent pin |
| kd166-witness | `ls /dev/sev /dev/tdx /dev/sev-guest` — no such files | environment-typed permanent (no confidential-compute hardware) |
| gws2-wasm-build-trial | graphlaw_wasm.wasm absent in sibling checkout | environment-typed (sibling checkout not built) |
| gl10-skeptic | recorded path `test/integration/graphlaw_skeptic` gone; `graphlaw_skeptic_court.exs` exists | premise rot (path renamed post-landing) |
| wasm1-otp29-sandbox-port | `:eaddrinuse` on fixed ports vs shared substrate | in-flight-lane interference (fixed-port boot vs live substrate) |
| bk71-census-drift | census gate fail-closed: in-flight `bkmon3r_deadjoin_court_test.exs` unregistered | in-flight-lane interference (fail-closed census, correct behavior) |
| fondrunner-court / fondrunner-otp29-pipeline | compile error connection.ex:3379 during run+retry; fresh compile now exit 0 | in-flight-lane interference (resolved between attempts) |
| gws7-wasm-abi-bridge | 5/6 — "gate 5: hung guest times out fail-closed and the pool self-heals" failed `{:gate_timeout, :fail_closed}` | real test failure on retry (load-sensitive candidate: 300 ms gate under concurrent lane load) |

## Typed SKIP inventory (in-browser smoke; typed by receipts, not this run)

Per `bkskipport-fetch-ports.md` (PARTIAL_ALIVE): the popcorn six are
permanent-with-reason — acr (face-absent), apim (wasm :httpc + face-absent),
egd (kd101-airgap), eh + topic (AMQP-over-raw-:gen_tcp impossible in wasm),
tls (real :ssl + on-disk CA impossible in wasm); dns = typed UNSUPPORTED
(RouteNotFound-404). No untyped skips surfaced by this witness run; the
WITNESS-STALE class is typed by the harness itself.

## Findings

1. gws7 gate-5 is the only unambiguous test-level failure on the converged tree
   — single retry failed identically; needs an owner (load-sensitivity suspect:
   300 ms fail-closed budget vs concurrent lanes).
2. Six receipts record non-executable commands (prose suffixes / truncated
   flags) — witness_all.py's extraction accepts prose into the cmd field; the
   harness should refuse commands that fail shell parse, loudly.
3. Two stale-evidence pins (expl9reg KD-174 marker, bkbshape ifMatch pin) and
   one renamed path (gl10) — premise rot; owners should re-pin or retire.
4. 24 placeholder receipts without Standing is expected mid-wave but means the
   witness-all gate cannot exit 0 until they seal.

## Falsifier

A rerun after the in-flight lanes land and the 6 malformed commands are
re-recorded should show failed ≤ 3 (gws7 + 2 environment-typed), i.e.
`[WITNESS-SUMMARY] failed=` above the 64 observed here on an identical tree
means this receipt's classification is stale.
