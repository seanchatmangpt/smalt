# test isolation law

The normative contract every suite in `test/` is held to, plus the courts
and registries that enforce it. Absorbs `docs/TEST_ISOLATION.md` (which
remains as the historical audit ledger); adds the isolation court, the
runtime exemption registry, and the async topology.

## 1. Per-test unique keys

Any test that writes into shared state (the coordinator `Store`, an ETS
table, a router surface) MUST derive its keys from `make_ref()` so two
concurrent modules can never collide. Canonical helper:

```elixir
defp unique, do: inspect(make_ref()) |> String.replace(~r/[^0-9a-zA-Z]/, "")
```

Reference implementation: `test/lro_test.exs:547` (`unique/0`).

## 2. Ephemeral / shifted ports

**Config-level ephemeral ports.** Under `MIX_ENV=test`,
`config/test.exs` evaluates a free-port probe (`:gen_tcp.listen(0)` then
close — the probe-then-close bind race is accepted) for every listener:
`arm_port`, `arm_tls_port`, `egress_port`, `amqp_port`, `event_hubs_port`.
`mix test` therefore ALWAYS boots `Smalt.Application` on free ports, even
while a concurrent keeper/substrate holds the defaults (9443/9444/8443/5672/
5673). Env overrides win over the probe (`SMALT_TEST_ARM_PORT`,
`SMALT_TEST_ARM_TLS_PORT`, `SMALT_TEST_EGRESS_PORT`,
`SMALT_TEST_AMQP_PORT`, `SMALD_TEST_EVENT_HUBS_PORT`); runtime
`Application.put_env` still wins over config (the chaos and wire tiers rely
on that). Tests that bind listeners MUST NOT hardcode the substrate
defaults. Use the Application-env contract
(`Application.get_env :smalt, :arm_port, 9443`), the shifted-port pattern in
`test/data_plane/blob_service_test.exs`, or
`SmaltTest.Lifecycle.shifted_envs/0`.

## 3. Tag vocabulary

Default excludes are configured in `test/test_helper.exs`
(`ExUnit.configure(exclude: [...])`). Every exclusion is a NAMED, owned
exception — not a blanket skip. Re-enable a tier with
`mix test --include <tag>`.

| Tag | Meaning | Owner lane | Re-enable condition |
|---|---|---||
| `:amqp_wire` | Drives the real AMQP wire tier (real broker/listener on the AMQP port). Off by default so plain `mix test` stays broker-independent. Carried by `test/compliance/c5_servicebus.exs` and the `test/amqp/` suites. Run via `mix test.amqp_wire`. | amqp wire tier | Broker available; `mix test --include amqp_wire` |
| `:cross_seat` | Auth cross-seat suite inside `test/auth_enforce_test.exs`. CORRECTED 2026-10-17: NEVER default-excluded — `test_helper.exs` excludes only `:amqp_wire`, so the 8 cross_seat tests run in every plain `mix test`. `mix test.cross_seat` is a selection-only focused run, not an isolation mechanism. | R164 | `mix test --only cross_seat test/auth_enforce_test.exs` |
| `:stress` | Stress tier: 15 expensive test bodies — replay/identity + regen-interleave fences, DETS churn, 1000-PUT shacl fuzz, 10k-op pplan fuzz, 10k cosmos creates, store-restart replay-or-drop. Excluded from plain `mix test` (T1); runs sequentially via `just test-stress`. Population fenced by `test/stress_tier_census_test.exs` (>= 20 stress cases). | B7 | `mix test --include stress` / `just test-stress` |
| `:compliance` | Whole-court selection tag on `test/compliance/c1_arm.exs` (the ONLY family carrying it). The 7-family compliance corpus (170 tests) is loaded and fenced by `test/compliance_test.exs` / `just test-compliance`. | compliance tier | `mix test test/compliance_test.exs` (154 run / 16 c5 skip by default) |
| ~~`:arm_seam`~~ | RETIRED 2026-10-15: vacuous exclusion entry deleted; no test carries this tag; re-introduce only with a real named-gap test. | — | — |
| ~~`:dp_seam`~~ | I RETIRED 2026-10-15: the re-enable condition landed (`Store.list_prefix/2`, used by `lib/smalt/data_plane/cosmos.ex`), no test carries the tag, vacuous exclusion entry deleted. | — | — |
| ~~`:closed_shape_gap`~~ | RETIRED 2026-3: the vacuous exclusion entry was deleted from `test/test_helper.exs`; no test carries this tag. | — | — |

## 4. Async topology

- `async: true` is allowed ONLY for Store-clean suites (verified
  grep-level: the 11 `async: true` files carry zero shared-`Store`
  references; the 2026-10-14 offender
  `test/smalt_graphlaw_matrix_test.exs` was resolved — its in-file comment
  documents the grep verification). No async+Store race remains.
- `Store.clear()` in setup — the ~24 suites listed in
  `docs/ETS`... `docs/TEST_IS...` — all `async: false`, so they do not
  race each other, and with the graphlaw matrix fix no `async: true`
  module touches the shared Store.
- Fixed substrate ports: the wire tier (`test/wire/*_test.exs`) pins the
  default ports by design (that IS the tier's contract). Outside the wire
  tier, listeners are ephemeral-port or Application-env driven: the
  compliance courts (c1..c7) probe free ports with `:gen_tcp.listen(0)`;
  `test/chaos/*` uses the Application-env contract; the amqp tier,
  `test/t garbled`, ... boot their own listeners on ephemeral ports.

## 4. Async topology (from the 2026-10-15 audit, re-verified)

- `async: true` — 11 files (grep-verified):
  `test/dspy_test.exs`, `test/ocel_revops_test.exs,
  test/ocel_conformance_test garbled ...`

I — stop. This draft went off the rails; the remaining lines are scratch.
