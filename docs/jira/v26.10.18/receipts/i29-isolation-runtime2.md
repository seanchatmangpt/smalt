# I29 receipt — runtime-twin isolation court, second slice (v26.10.18)

Standing: FAIL (court exit 1) — counted residue REGRESSED vs run-e baseline under fleet contention.
Context: solo (single lane; machine under concurrent fleet load — see Deviations).

Subject: `/Users/sac/smalt` working tree, 2026-10-18.
No git, no edits to `lib/`/`test/`, no kills. Only this receipt written.

## Command

```
python3 scripts/isolation_court.py --runtime-only   # exit 1, verdict=FAIL
```

Raw twin log: `tmp/isolation-court-runtime.out` (7.35 MB → grew to full suite).

## Result

- Suite: `tests=2829 failures=103`, `mix exit=2` (failures under fleet contention,
  consistent with the run-e receipt's 113 failures under load; serial
  `--max-cases 1`, SmaltTest.IsolationFormatter).
- Twin raw: **22 modules_leaked** (SUMMARY line).
- After the 14 typed exemption patterns: **13 COUNTED** (verdict FAIL).
- Exemptions file: `test/support/isolation_runtime_exemptions.exs` (14 patterns).

## Trend vs azb-11b (run-e: 2784 tests, 15 raw → 3 counted)

Raw twin residue regressed: 15 → 22 raw, 3 → 13 counted. Two structural notes:

1. The run-e receipt states two counted classes were fixed AFTER run-e
   (SecurityHardening maa, WireTierRefusalSweep ports) and SweeperTest is
   clean x3 on quiet runs; this run is NOT that quiet full re-run, so the
   honest cross-twin comparison is noisy — but the counted set here is
   dominated by env deltas, which are never exemptable, so the regression
   is real, not classification noise.
2. All 13 counted blocks carry **env deltas** (env leaks are never
   exemptable); none is a names-only counted block. Two show names_new
   side-effects (ArmWireTest → Smalt.Affidavit.WasmEngine boot shift).

### The 13 counted modules (with env deltas witnessed)

| module | env keys leaked |
|---|---|
| Smalt.EventGridConformanceTest | arm_tls_port, event_hubs_port (x2 values each) |
| Smalt.Amqp.SasVerifierTest | sb_endpoint, sb_shared_key (incl. literal SAS key value) |
| Smalt.Azsim.SovereignMidnightTest | arm_rate_limit (:infinity) |
| Smalt.ArmGateway.LRO.NotifierTest | lro_delay_ms (0/20) |
| Smalt.Amqp.CbsRouterTest | sb_shared_key (literal key value) |
| Smalt.Wire.ArmWireTest | arm_port, egress_port, amqp_port (x2 values each) |
| Smalt.Amqp.BrokerFacadeTest | amqp_sweeper_tick_ms (20) |
| Smalt.ArmCorsTest | arm_cors_origins |
| Smalt.EtsBaselineIdentityTest | maa_measurement_baseline (x2) |
| SmaltServicesTest | maa_measurement_baseline (x2) |
| Smalt.MixAuthScopeTest | auth_mode (:anonymous→:enforce) |
| SmaltTest.Azsim.ControlPlaneTest | arm_gateway ([strict_version_validation: true]) |
| Smalt.Amqp.FrameCodecTest | primitive_codec (TestPrimitiveCodec) |

(The other 9 raw blocks — Lens5Fuzz, StoreDetsGrowth, R129SessionGate,
AffidavitWasm, AmqpWire, PPlan, WasmEngine family x2, CanonicalProjection —
were EXEMPT by pattern; CanonicalProjectionTest is now exempt where run-e
counted it, confirming the 11b put_restored fix held.)

## Deviations

- **Fleet contention**: 103 test failures (mix exit=2) under concurrent
  fleet load — same class as run-e's 113 failures; these are not counted as
  isolation findings but make the run non-quiet. The 11b next-slice
  falsifier (clean-tree full twin → 0 counted on a QUIET run) remains open
  and is still the right next step; this solo run does not satisfy it.
- The court's counted classification prints to stdout only; the raw twin
  log is `tmp/isolation-court-runtime.out`.

## Falsifier for next slice

Quiet-machine re-run to `runtime verdict=PASS` (0 counted). Highest-value
repairs: SasVerifier/CbsRouter (literal SAS keys surviving suite-wide is the
worst class here), then the port-key family (EventGrid/ArmWire).
