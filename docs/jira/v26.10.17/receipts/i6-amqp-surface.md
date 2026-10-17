# I6 — AMQP surface verify-only receipt

- Date: 2026-10-17T21:47:03Z
- Lane: I6 of `docs/jira/v26.10.17/_LANES.md`
- Lease: `lib/smalt/messaging/` + `test/amqp/` — lib/ is final; verify-only, no edits made
- Build root: `MIX_BUILD_ROOT=_build-lane6`
- Standing: PASS (offline tier green, wire-tier pinions green)

## Commands and output

### 1. Offline AMQP tier

    MIX_BUILD_ROOT=_build-lane6 mix test test/amqp/
    -> 331 tests, 0 failures (45 excluded)

(45 excluded = the default-excluded `:amqp_wire` tier.)

### 2. Named test files

    MIX_BUILD_ROOT=_build-lane6 mix test test/amqp/connection_test.exs test/amqp/frame_codec_test.exs test/amqp/sas_verifier_test.exs test/amqp/event_hubs_test.exs test/amqp/atom_bridge_test.exs
    -> 108 tests, 0 failures (22 excluded)

### 3. Pinion witness runs (`--include amqp_wire`)

Fixed-partition pinion (KD-76, out-of-pin attach → typed detach), `test/amqp/event_hubs_test.exs`:

    MIX_BUILD_ROOT=_build-lane6 mix test --include amqp_wire test/amqp/event_hubs_test.exs
    -> 34 tests, 0 failures
    witnessed firing:
      * test KD-76 partition-key routing out-of-pin partition attach is refused:
        attach echo then typed detach [L#1417] (2.1ms)

SASL ANONYMOUS-only pin, `test/amqp/connection_test.exs`:

    MIX_BUILD_ROOT=_build-lane6 mix test --include amqp_wire test/amqp/connection_test.exs
    -> 15 tests, 0 failures
    witnessed firings:
      * test SASL ANONYMOUS handshake then open and begin [L#92] (0.9ms)
        — asserts advertised mechanisms == [{:symbol, "ANONYMOUS"}] exactly
      * test non-ANONYMOUS SASL mechanism is refused with outcome code 1 and teardown [L#133] (0.8ms)

SAS verifier tier, `test/amqp/sas_verifier_test.exs`:

    MIX_BUILD_ROOT=_build-lane6 mix test --include amqp_wire test/amqp/sas_verifier_test.exs
    -> 35 tests, 0 failures

## Result

- Total: 331 offline AMQP tests, 0 failures. Named-file subset: 108 tests, 0 failures.
- Both pinions pass with witnessed firings under `--include amqp_wire`:
  fixed-partition out-of-pin attach → typed detach (KD-76, event_hubs_test.exs:1417)
  and SASL ANONYMOUS-only (connection_test.exs:92, :133).
- Errors: 0. No lib/ edits (verify-only lease honored). No git actions.
