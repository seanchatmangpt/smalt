# Receipt: JA-15b — non-egress gap adoption (G1, G4, G5)

Context: solo

**Standing:** **PASS (court 7/7, two consecutive green runs: tmp/ja15b-court8.log + tmp/ja15b-court9.log; regression faces 17 passed, tmp/ja15b-regress.log; G5 non-vacuity witnessed: config block removed → leg 7 flips to Failed, block restored → passes) + G3's egress half carried to BK-56**

Date: 2026-10-21 · Lane: JA-15b · Build root: `_build-ja15b` ·
Toolchain: OTP 29.1.2 + Elixir 1.20.4-otp-29 (`.tool-versions` pin; ambient shell
defaults to OTP 28 — PATH corrected via `/Users/sac/.asdf/shims` for every command).

## Subject

Adopting the non-egress typed gaps from `ja15-error-logger-audit.md`:
G1 (ledger label schema), G4 (cosmos/blob wire refusals typed-but-silent),
G5 (metadata correlation ids invisible under the default formatter).
G2 (cosmos/blob/KV error-path telemetry) was NOT in scope; G3's
egress_router.ex half is BK-56's file — carried.

## Per-gap fix

- **G1** `lib/smalt/messaging/amqp10/amqp10_ledger.ex` — the settled-ledger
  owner label `{__MODULE__, :settled_ledger_owner}` (bare tuple, not
  service/role queryable) is now the IMPL-6 map schema
  `%{service: :amqp, role: :settled_ledger_owner, correlation_id: :amqp10_settled}`.
- **G4** — site-level Logger at both refusal funnels:
  - `lib/smalt/data_plane/cosmos.ex` `error_response/5` (the point-op refusal
    funnel, incl. the audited malformed-doc-id 400): `Logger.warning`
    `[cosmos] wire refusal status= code= db= coll= message= correlation_id=cos-<n>`,
    plus `Logger.metadata(correlation_id:, cosmos_db:, cosmos_coll:)` on the
    request process so the id rides any subsequent crash report on that process.
  - `lib/smalt/data_plane/blob_error.ex` `send_error/5` (the KD-142 XML
    envelope renderer): `Logger.warning` `[blob] wire refusal status= code=
    path= message= correlation_id=blob-<x-ms-request-id>` — the wire's own
    request id.
- **G5** `config/config.exs` — minimal config-level fix on the default
  formatter:

  ```elixir
  config :logger, :default_formatter,
    format: "$time $level[$metadata] $message\n",
    metadata: [:correlation_id]
  ```

## Court (test/internal/ja15_error_logger_court_test.exs — 4 → 7 legs)

5. **G1 label schema**: real `Smalt.Amqp10.Ledger.ensure/0`, label read back
   via `:erlang.process_info(pid, :label)` — map schema with
   `service: :amqp, role: :settled_ledger_owner, correlation_id: :amqp10_settled`
   asserted field-wise, plus real `:amqp10_settled` table existence/protection
   (`:public`) checks.
6. **G4 cosmos refusal site log**: real `create_doc` with `"id" => "bad/id"`
   (the audited silent witness) → typed 400 on the wire AND site log line
   `[cosmos] wire refusal status=400 code=BadRequest db=ja15b ...` with
   `correlation_id=cos-<n>`. capture_log, real process, no mocks.
7. **G5 metadata rendering** (config-gated, no capture-time overrides):
   plain `capture_log` — the formatter inherits the config
   `:logger, :default_formatter` defaults — a `Logger.metadata`
   correlation id renders on the formatted line
   (`correlation_id=ja15b-meta-42`; the 1.15+ default formatter renders
   metadata as key=value, not the bracket form). Non-vacuity: removing the
   config block flips this leg to Failed (witnessed), restoring passes.

## Disclosure: legacy leg 1 assert amended (map key order not pinned)

The audit's leg 1 asserted the crash report renders
`Process Label: %{service: :amqp, role: :listener, correlation_id: :sb}` as an
exact string. On this tree the label map renders with different key order
(`%{service: :amqp, correlation_id: :sb, role: :listener}` — key order of the
labeled map is not a stable property across configs). The assert is amended to
field-wise: the Process Label line must be present and carry all three IMPL-6
fields. Same substantive law, order-independent; court re-witnessed 7/7 twice.

## Regression faces

`mix test test/integration/blob_xml_error_test.exs test/internal/cosmos_kd65_scripts_test.exs test/internal/cosmos_analytical_ttl_test.exs`
→ `17 passed` — blob XML error + cosmos faces green under the new site logs.

## Carried

- **G3 egress half**: `with_valid_body`/`safe_dispatch` in egress_router.ex
  are unwired (zero callers). egress_router.ex is BK-56's file — carried to
  that lane; no edits made here.
- **G2** (cosmos/blob/KV error-path telemetry) not in scope; still open.

## Falsifier / replay

```
PATH=/Users/sac/.asdf/shims:$PATH MIX_BUILD_ROOT=_build-ja15b \
  mix test test/internal/ja15_error_logger_court_test.exs
```

on HEAD must return `7 passed`. Reverting the G1 label to the tuple flips leg
5 (not a map); removing the `Logger.warning` from cosmos.ex `error_response/5`
flips leg 6; dropping the `config :logger, :default_formatter` block from
config/config.exs flips leg 7 (metadata id stops rendering).

Court file: `/Users/sac/smalt/test/internal/ja15_error_logger_court_test.exs`
Receipt: `/Users/sac/smalt/docs/jira/v26.10.21/receipts/ja15b-gap-adoption.md`
