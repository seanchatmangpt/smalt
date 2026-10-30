# R Env Artifacts Receipt (L05)

Standing: PARTIAL_ALIVE — the three artifact-class environments are fully
provisioned and their named tests execute with real verdicts (no
error-by-missing-artifact, no silent skip): GateCourt 6/6 PASS, Ath3 PASS,
Kd115 PASS, EventGridWebhook 10/10 PASS. One test in the (a) class is NOT
environment: TraceSessionCourtTest "TRACEBUG boundary pin" fails
deterministically on a quiet tree (2/2 runs, load < 7) — per r4's own
falsifier clause it moves to class (d) with the evidence below.

## Method

- Lane L05 (environment/artifact provisioning), third attempt; prior-attempt
  recon reused and re-verified on disk before use (digests re-read, not
  cited from memory).
- Every named (a)-class test file from `r4-baseline-triage.md` was executed
  read-only under `MIX_BUILD_ROOT=_build-l05` (lane build-root lease), with
  the repo-pinned toolchain (asdf elixir 1.20.4-otp-29 / erlang 29.1.2;
  Homebrew elixir 1.19.5 is refused by the `~> 1.20` pin — first run exit 1
  before the PATH fix, kept as evidence).
- No lib/test file edits; no git state commands; no Process.sleep; bounded
  polls only (probe `tryConnect` port polls; ExUnit receive windows).
- Verify commands (all `cd /Users/sac/smalt`):

```
MIX_BUILD_ROOT=_build-l05 mix test test/graphlaw_ex_gate_court_test.exs
MIX_BUILD_ROOT=_build-l05 mix test test/integration/ath3_law_court_test.exs
MIX_BUILD_ROOT=_build-l05 mix test test/internal/kd115_credit_first_delivery_test.exs
MIX_BUILD_ROOT=_build-l05 mix test test/integration/trace_session_court_test.exs \
  test/integration/event_grid_webhook_test.exs
```

## Per-artifact table

Per-artifact inventory (paths verbatim; digests sha256, head 16 hex):

`/Users/sac/smalt/test/priv/graphlaw/graphlaw.wasm`
: 74,097,211 B; sha256 `34fd4ada7ffe57f3…`; mtime Oct 29 21:57; placed by
  the prior L05 attempt, re-verified this session by digest. Consumer:
  GateCourt default `@wasm_path` (baseline failures: tests 37-39). Source:
  copy of
  `~/graphlaw/target-tagfinal/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm`.

`/Users/sac/smalt/verification/ts/node_modules/rhea`
: v3.0.5; mtime Oct 29 21:58; install state found present, re-verified
  (version + resolution) this session; no npm command needed. Provenance:
  transitive of `@azure/service-bus ^7.10.0` → `rhea-promise ^3.0.3` →
  `rhea ^3.0.5`. Consumer: Kd115 probe resolves it via
  `createRequire(verification/ts/package.json)("rhea")`; node v26.10.0.

`/Users/sac/graphlaw/target/release/graphlaw-run-eh`
: 85,522,800 B; sha256 `165beccbb82f81ae…`; mtime Oct 29 23:22; copied this
  session from `~/graphlaw/target-tagfinal/debug/graphlaw-run-eh`
  (debug-profile build, same tagfinal generation as the wasm). Consumer:
  Ath3 `Ath3.Wasm.runner/0`.

`/Users/sac/graphlaw/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm`
: 74,097,211 B; sha256 `34fd4ada7ffe57f3…`; mtime Oct 29 23:22; copied this
  session from the tagfinal wasm. Consumer: Ath3 `Ath3.Wasm.wasm_path/0`
  (test-side identity digest).

`/Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm`
: 74,097,211 B; sha256 `34fd4ada7ffe57f3…`; mtime Oct 29 23:28; copied this
  session. Consumer: the runner binary's baked-in default (it spawns bare:
  no `--wasm` flag, no `GRAPHLAW_WASM` env).

Note: `~/graphlaw/target/` did not exist before this lane (only
`target-tagfinal`/`target-final`/`target-arr-P19-fuzz`); all three files
under it are byte-verified copies; no source, manifest, or lockfile in
`~/graphlaw` was touched.

## Verification output (embedded, real)

GateCourt — exit 0:

```
Running ExUnit with seed: 322490, max_cases: 32
......
Finished in 34.0 seconds (0.00s async, 34.0s sync)

Result: 6 passed
GATECOURT_EXIT=0
```

The `[SKIP] GL28-2 gate courts: no wasm artifact at ...` loud skip did not
fire; the setup registered the real host
(`start_supervised!({GraphlawEx, wasm_path: @wasm_path, expected_sha256: :unpinned})`)
and `GraphlawEx.Host.info` returned a 64-hex engine digest per court. The
three baseline (a) failures — tests 37 "tampered payload byte refuses typed
and the Store readback is unchanged", 38 "replayed receipt_blake3 is refused
on the second presentation", 39 "gate inverted (enabled: false) lets the
tampered payload land" — are among the 6 green. Baseline (b) test 36
("16 MiB + 1 body refuses :smalt_oversize", engine_digest dirty-tree class)
also passed; that flip is noted for the r4 falsifier re-run, not claimed as
fixed by this lane.

Ath3 — exit 0:

```
  ok  graphlaw.wasm artifact identity: sha256 34fd4ada7ffe...
  ...
  ok  non-vacuity: dropping a leaf changes the Merkle root
documents: 3 | production: D-1 | quarantined: D-2 (0-byte) | andon: D-3
sealed leaves: 14  merkle_root: 4f4f5cc237110488047c7219d40b8010ba968ea751f78824f2b858e374edc31d
ATH-3 COURT: PASS
.
Finished in 5.2 seconds (0.00s async, 5.2s sync)

Result: 1 passed
ATH3_EXIT=0
```

Kd115 — exit 0 (probe stdout is captured by the test; the test's own
assertions prove the PASS lines appeared):

```
Running ExUnit with seed: 88185, max_cases: 32
.
Finished in 52.4 seconds (0.00s async, 52.4s sync)

Result: 1 passed
KD115_EXIT=0
```

Asserted probe verdicts (test asserts these strings):
`PASS plain-credit-first`, `PASS session-credit-first`,
`PASS kd116-session-settle`. The probe booted its private substrate block
b13 (ports 39130-39135, pre-checked free) and swept it at exit — post-run
port poll: swept, no orphan beam.

TraceSession + EventGridWebhook — exit 2, twice (first run 12/13, re-run
with full capture for the failure block):

```
1) test TRACEBUG boundary pin: self-traced process still drops its own events (destination-based) (Smalt.Test.Internal.TraceSessionCourtTest)
   test/integration/trace_session_court_test.exs:53
   Assertion with >= failed
   code:  assert :trace.function(session, mfa, [], [:local]) >= 1
   left:  0
   right: 1
   stacktrace:
     test/integration/trace_session_court_test.exs:68: (test)

Result: 12/13 passed
```

EventGridWebhook: all 10 tests pass, including the baseline (a) failure
"bridge: integration-plane fan-out and webhook receiver are separate faces"
— the already-started singleton race did not reproduce on a quiet tree
(load 6.0-6.8, 2/2 runs green). Stays class (a) flake, confirmed by re-run.

## Classification update (r4 falsifier clause)

- TraceSessionCourtTest "TRACEBUG boundary pin" (test :53, assert :68):
  failed 2/2 on quiet tree, load < 7, byte-identical assert values to the
  baseline (left 0 / right 1). Host load was the triage's rationale for
  class (a); the quiet-tree re-run removes it. This is a real defect
  (self-traced positive control records 0 events — the court's own
  destination-based-suppression documentation says the SAME session must
  record the calls when executed on a separate worker). Reclassify (a)→(d);
  out of L05 provisioning scope (needs lib/ or test-code work, not
  artifacts). The trace target `Smalt.EgressRouter.egress_cors/2` still
  exists (lib/smalt/egress_router.ex:74, defp), so it is not a D1
  missing-function casualty.
- Class (a) verdicts after provisioning: 8 of 9 baseline (a) failures are
  now green (GateCourt 3, Kd115 1, Ath3 2 across both logs, EventGrid 2);
  1 reclassifies to (d) (TraceSession pin).

## Disclosures

- Writes outside /Users/sac/smalt: three byte-verified copies into the NEW
  `~/graphlaw/target/` dir (runner, wasm x2 layouts) — the exact paths the
  Ath3 court and the runner's baked default resolve to; no other writes
  outside the lane lease `_build-l05`, `/tmp/l05-flakepair.log`, and this
  receipt.
- The Ath3 runner is a debug-profile cargo build copied to the
  `target/release/` path the test hard-codes. The court passes with it; if a
  release-profile runner is later required, that is a rebuild, not an
  artifact placement.
- Divergence note: the Ath3 test reads its identity digest from
  `target/wasm-abi/wasm32-wasip1/wasm/` while the runner binary's default is
  `target/wasm32-wasip1/wasm/`; both are provisioned from one generation
  (tagfinal, `34fd4ada…`). First Ath3 run failed typed at the runner leg
  (`cannot read wasm artifact .../target/wasm32-wasip1/... No such file`)
  before the second layout was placed — evidence the pair layout is
  load-bearing, not incidental.
- Pre-existing `erl_crash.dump` (9.1 MB, mtime Oct 29 22:41) sits in the
  smalt root, predating this lane's first execution (~23:22); not produced
  and not removed by L05.
- Toolchain: repo pin requires asdf elixir 1.20.4-otp-29; lanes without the
  shims on PATH will exit 1 with the mix version gate. PATH used:
  `~/.asdf/installs/elixir/1.20.4-otp-29/bin:~/.asdf/installs/erlang/29.1.2/bin`.

## Falsifier

- GateCourt/Ath3/Kd115: delete any one provisioned artifact and its test
  must flip to loud skip or typed File.Error — the same evidence r4 quoted.
  Re-provision per the table and they flip back. This run's own history
  already demonstrates the flip once (Ath3 runner-leg failure before the
  second wasm layout existed).
- TraceSession pin: if any lane re-runs it on a quiet tree and it passes,
  the (d) reclassification above is wrong and the row returns to (a) with a
  receipt update.

## See Also

- `docs/jira/v26.10.29/receipts/r4-baseline-triage.md` (class list, WO-4)
