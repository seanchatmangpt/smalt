# I29 receipt — env-leak remediation, the 13 counted modules (v26.10.18)

Standing: PASS (static gate GREEN, all 13 counted modules green ×1 on private roots; quiet runtime twin court launched, see Verification).
Context: slice(env-leak-remediation, i29 isolation batch, 2026-10-18)

Subject: `/Users/sac/smalt` working tree, 2026-10-18.

## What was wrong

The runtime-twin court (i29-isolation-runtime2) counted 13 modules with
suite-wide env deltas. Root causes found, worst first:

1. **Literal SAS-key class** (`:sb_shared_key` / `:sb_endpoint`):
   - `test/amqp/flow_credit_test.exs` — bare `put_env` of a random 48-byte
     key + **delete-only** on_exit: a config.exs present-with-nil key
     (`config :smalt, :sb_shared_key, nil`) was flipped to ABSENT for the
     rest of the suite. This is the actual literal-key survivor; its residue
     was charged to neighbor modules (CbsRouter/SasVerifier blocks).
   - `test/amqp/sas_verifier_test.exs` — two hand-rolled `if prev == nil`
     restores ("dev fallback key", "endpoint/0 defaults") converted
     present-with-nil → absent and were not `SmaltTest.Env`-canonical.
2. **Port family** (`arm/egress/amqp/event_hubs_port`): `arm_wire_test.exs`
   and `wire_tier_refusal_sweep_test.exs` applied their saved prev map
   BEFORE `Lifecycle.restore_app/0`, which then clobbered the restore with
   the shifted values (wire_tier even carried a comment pinning the wrong
   order). arm_wire also restored `auth_mode` with a non-unset-aware put.
3. **The rest**: hand-rolled prev restores without the `:__unset__`
   sentinel (sovereign_midnight restored `:arm_rate_limit` to a defaulted
   `:infinity`, minting an absent→present delta; lro Notifier setup restored
   nil prev with a SILENT NO-OP, leaking `:lro_delay_ms = 20`), plus
   truthiness restores (`if prev` in frame_codec) and capture/put mismatches
   in arm_cors/broker_facade/ets_baseline.

Modules already canonical with no in-file defect — `CbsRouterTest`,
`EventGridConformanceTest`, `SmaltServicesTest`, `SmaltTest.Azsim.ControlPlaneTest`
(already `Env.put_restored`/`Env.with` throughout) — were **attribution
neighbors**: their counted blocks carried residue whose writers live in the
families above. No edits were needed; each ran green ×1 after the fixes.

## Changes (assertions preserved verbatim; no `lib/` edits; no sleeps)

| file | change |
|---|---|
| test/amqp/sas_verifier_test.exs | 2 hand-rolled restores → `SmaltTest.Env.put_restored` capture-then-delete |
| test/amqp/flow_credit_test.exs | bare put_env + delete-only on_exit → `put_restored(sb_shared_key: <rand>)` |
| test/amqp/cbs_router_test.exs | none (already canonical; attribution neighbor) |
| test/wire/arm_wire_test.exs | 4 port pins + `auth_mode` → `put_restored`; prev map deleted |
| test/wire_tier_refusal_sweep_test.exs | 4 port pins → `put_restored`; restore_app ordered BEFORE the LIFO put_restored restore |
| test/arm_cors_test.exs | setup capture-then-delete + in-test muts → `put_restored` |
| test/amqp/broker_facade_test.exs | `own_sweeper!` tick flip → `put_restored(amqp_sweeper_tick_ms: ...)` |
| test/lro_test.exs | both setups + 5 in-test muts → `put_restored`; unused `restore_env/2` helper removed |
| test/smalt_ets_baseline_identity_test.exs | unset-aware hand-rolled → `put_restored(lro_retention_ms: 0)` |
| test/amqp/frame_codec_test.exs | setup + 4 in-test codec swaps → `put_restored` (after-delete blocks removed) |
| test/azsim/sovereign_midnight/sovereign_midnight_test.exs | rate-limit flip → `put_restored(arm_rate_limit: 5)`; broken `put_env(prior_limit)` on_exit removed |
| test/eventgrid_conformance_test.exs | none (canonical via `Wire.pin_ports!`; attribution neighbor) |
| test/smalt_services_test.exs | none (already `put_restored`; attribution neighbor) |
| test/azsim/control_plane_test.exs | none (already `Env.with`; attribution neighbor) |
| test/mix_auth_scope_test.exs | none (nil-preserving on_exit restore already correct; attribution neighbor) |

## Verification

```
python3 scripts/isolation_court.py --static-only
  -- OFFENDERS: none -- verdict=PASS static=GREEN fixtures=REFUSED-OK
```

(First pass after editing flagged 3 sites introduced by my own conversions —
arm_cors:15, lro_test:1073, frame_codec:769 — all converted to
`put_restored` and re-gated to GREEN. Fail-closed fixtures PASS/REFUSE.)

Per-file runs (scripts/fast_test.sh, per-hash private build roots):

- sas_verifier + flow_credit + arm_cors: 38 tests, 2 failures → both arm_cors
  presence-with-nil conversion bug (my own), fixed to capture-then-delete →
  arm_cors rerun: 3 tests, 0 failures
- broker_facade + lro + ets_baseline + frame_codec + sovereign_midnight:
  101 tests, 0 failures
- arm_wire + wire_tier_refusal_sweep: 9 tests, 0 failures
- rerun after second conversion round (frame_codec + lro + arm_cors +
  sas_verifier + flow_credit + ets_baseline): 116 tests, 0 failures
- cbs_router + eventgrid + smalt_services + control_plane + mix_auth_scope:
  48 tests, 0 failures

## Runtime court

A quiet `--runtime-only` twin run was launched after the edits
(`tmp/isolation-court-runtime3.out`). Its SUMMARY line is the open falsifier:
0 counted ⇒ the i29-isolation-runtime2 regression closes; the next-slice
falsifier from the previous receipt (quiet full twin → 0 counted) stands
until that line reads `modules_leaked` counts only exempted name shifts.

## Deviations

- The runtime court could not complete inside this slice's time budget at
  receipt-writing time; per-file green ×1 + static GREEN is the landed
  verification, per the task's fallback ladder.
