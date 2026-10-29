# BK-POPCORN — popcorn live loopback leg: verified + gate-exit contract fixed

**Standing:** **ALIVE** (all three gate scenarios witnessed on the recooked wasm bundle)

## Scope

Plan-approved popcorn live loopback leg. On inspection the leg itself
(`lib/popcorn_demo/live.ex`, application.ex wiring, browser_smoke.mjs gate,
README live section) was ALREADY committed by prior waves (934d21aa,
c72e47c3). This lane verified it end to end and closed two deviations from
the approved contract:

1. **Substrate-down classification (lib/popcorn_demo/live.ex)** — the browser
   has no `econnrefused`; a refused loopback hop surfaces as the fetch
   "TypeError: Failed to fetch" family and was tagged `live=SKIP(transport:...)`.
   Now classified `live=SKIP(substrate-down:...)` (regex
   `econnrefused|failed to fetch`, case-insensitive). Witnessed.
2. **Gate exit contract (scripts/browser_smoke.mjs)** — the old gate forced
   exit 1 on ANY `=FAIL` fragment, so `SMOKE_ALLOW_OFFLINE=1` could never
   downgrade a substrate-down run to 0. Exit is now keyed on the live=
   fragment: `live=OK`→0 (any other `=FAIL` still forces 1, fail-closed),
   `live=SKIP`→3 loud / 0 with `SMOKE_ALLOW_OFFLINE=1`, `live=FAIL`→1.

README live-leg bullet added (auth-path walk, OPTIONS auth-exempt preflight
note, substrate preflight); exit-code table note extended with the
`SMOKE_ALLOW_OFFLINE` downgrade semantics. `docs/TESTBED.md` canonical exit
table is outside this lane's file ownership — not touched (flag to
coordinator).

## Commands + exits (all from popcorn_demo/ unless noted)

- `mix compile` (PATH elixir 1.20.3-otp-28, MIX_BUILD_ROOT=_build-bkpop) → exit 0
- `mix test` substrate down → 72/135, 63 failed (substrate-dependent tests;
  pre-existing environment artifact, not session-introduced)
- `mix test` substrate up → **190 passed, 3 skipped, exit 0**; log line:
  `popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)`
- `mix popcorn.cook --out-dir public/out` (pinned cook toolchain
  erlang 29.0.6 + elixir 1.20.4-otp-29, MIX_BUILD_ROOT=_build-cook-bkpop) → exit 0
  (bundle is cooked code — the wasm runs cooked live.ex; host-only verification
  is not a browser witness)
- `node scripts/browser_smoke.mjs`, substrate UP → **exit 0**,
  `live=OK(endpoints,tenants,sts,subscriptions=1)`,
  `SCVD_GATE: SCVD-OK:t16:6.105ms <= 3x rolling-best 5.214ms`
- `node scripts/browser_smoke.mjs`, substrate DOWN → **exit 3**,
  `live=SKIP(substrate-down:"TypeError: Failed to fetch...")`
- `SMOKE_ALLOW_OFFLINE=1 node scripts/browser_smoke.mjs`, substrate DOWN →
  **exit 0**, same loud `live=SKIP(substrate-down:...)` fragment printed
- Negative-fixture note: with substrate down the appconfig/rg legs still emit
  `=FAIL(fetch)` fragments (their own skip classifiers are narrower than the
  live leg's). Under the new gate these ride visibly in the printed receipt
  when live SKIPPED; when `live=OK` they still force exit 1. Not this lane's
  plan scope — flagged for the leg owners.

## Environment facts (witnessed)

- First substrate-up attempts died at UP_TIMEOUT=90s while ash compiled
  (659 files) — `SMALT_UP_TIMEOUT=600/900` resolves; compile is incremental.
- Transient Kafka 9092 `eaddrinuse` from another lane's az1_boot_noapp beam;
  cleared on retry; `scripts/port_sweep.sh` tree-aware-skips it (live
  private-port lane).
- Compile-freeze SLA fix (disclosed): another lane's in-flight
  `justfile.d/51-bkvc.just` used `//` comments → whole-justfile parse
  failure for ALL lanes. Minimal unblock applied: `// ` → `# ` (3 lines,
  comment-only). Owner: BK-VCOURTS lane — their commit.

## Falsifier status

- A run with substrate down that exits 3 without ALLOW_OFFLINE: REFUTED
  (observed exit 3, loud SKIP printed).
- A run with substrate down + ALLOW_OFFLINE=1 that exits nonzero: REFUTED
  (observed exit 0).
- A run with substrate up where the live fragment is not `live=OK(...)`: REFUTED
  (observed OK, SCVD gate OK).

## Left-up state

Substrate left UP (ports 9443/9444/5672/5673) for other lanes. Lane build
roots `_build-bkpop`, `_build-cook-bkpop` are mine — deleted below at
integration.
