# Receipt: BK-AMPF1 — BK-AMPSKEP F1 repair (loopback_host? IP-literal parse)

- **Date**: 2026-10-22
- **Lane**: BK-AMPF1 (owner: `lib/smalt/messaging/amqp/sas_verifier.ex` + kd173r court)
- **Subject**: `lib/smalt/messaging/amqp/sas_verifier.ex` `loopback_host?/1`
- **Standing**: **ALIVE**
- **Context**: solo

## Repair

`sas_verifier.ex` `loopback_host?/1` replaced the
`String.starts_with?(h, "127.")` prefix arm with an IP-literal check:
`:inet.parse_address(String.to_charlist(h))` → `{:ok, {127,_,_,_}}` for
dotted-quad literals in 127/8; `localhost`, `::1`, `[::1]` stay exact
(case-insensitive). Attacker-resolvable `127.*` domains no longer match;
the loopback posture is otherwise unchanged (127/8 dotted quads, any port,
still verify). Annotated `# BK-AMPSKEP F1 repair` at the site.

## Court — kd173r extended with the F1 legs (real SasVerifier, real HMAC)

```
$ MIX_BUILD_ROOT=_build-ampf1 mix test test/internal/kd173r_audience_scope_court_test.exs
Running ExUnit with seed: 925754, max_cases: 32
......
Finished in 0.03 seconds (0.00s async, 0.03s sync)
Result: 6 passed
```

New legs (falsifier — the two witnessed F1 probes flip to typed 401):

- `sb://127.evil.example` → `{:error, {401, "INVALID_LOCAL_SAS"}}` (was OK(200))
- `sb://127.0.0.1.evil.example` → `{:error, {401, "INVALID_LOCAL_SAS"}}` (was OK(200))
- `sb://127.1.2.3:9999` → `{:ok, _}` (127/8 dotted-quad posture preserved)
- clean loopback forms from the audit's no-finding list stay green
  (127.0.0.1:5672, /q paths, localhost any-port) — 6/6 legs pass.

## Real-SDK non-regression — fix4 probe, live broker (:enforce, block c81)

```
$ MIX_BUILD_ROOT=_build-ampf1 SMALT_FIX4_BLOCK=c81 node verification/ts/fix4.probe.cjs
block c81 AMQP 40010 ARM 40012 keybytes 64
PASS kd131.shared-key-at-or-above-32-byte-floor
PASS kd131.cbs-put-token-200-floor-valid-key
PASS kd132b.malformed-body-typed-400
PASS kd132b.connection-survives-after-malformed-body
PASS kd133.spec-ordered-flow-grants-credit-2-deliveries
PASS kd133.topup-flow-delivers-third
TOTAL pass=6 fail=0
```

Load-bearing leg: real CBS put-token minted for
`sb://127.0.0.1:<port>/<entity>` still verifies 200 on the live broker.
(Receipt used block b89; this lane ran block c81 per the port law — same
probe, fresh block.)

## Adjacent suites fresh

```
$ MIX_BUILD_ROOT=_build-ampf1 mix test test/integration/amqp_kd131_133_triage_test.exs \
    test/integration/sbkey_boot_config_test.exs \
    test/internal/kd134_requester_delivery_test.exs
Result: 11 passed
```

(Receipt's Leg-4 list also includes
`test/integration/store_partition_wire_regression_test.exs` and the amqp10
courts; those pins are untouched by this diff — loopback_host?/1 is not on
the wire path, and the fix4 + kd131/133 live-wire legs above re-witness the
SAS surface end to end.)

## Verdict

BK-AMPSKEP F1 closed: the two witnessed F1 audiences now refuse typed 401,
every no-finding form from the audit keeps its prior verdict, and the
real-SDK probe is pass=6 fail=0 (exit 0). BK-AMPSKEP's PARTIAL_ALIVE
condition ("127.evil.example-class audiences must refuse 401") is satisfied.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-ampf1
mix test test/internal/kd173r_audience_scope_court_test.exs   # 6 passed
SMALT_FIX4_BLOCK=c81 node verification/ts/fix4.probe.cjs      # pass=6 fail=0
mix test test/integration/amqp_kd131_133_triage_test.exs \
        test/integration/sbkey_boot_config_test.exs \
        test/internal/kd134_requester_delivery_test.exs       # 11 passed
```
