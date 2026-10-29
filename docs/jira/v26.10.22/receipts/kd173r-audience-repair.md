# Receipt: KD-173R — KD-172 `sb:` audience wildcard repaired (host-scoped) + closed

- **Date**: 2026-10-22
- **Lane**: KD-173R (repair lane dispatched on the KD-SASV registration)
- **Subject**: `lib/smalt/messaging/amqp/sas_verifier.ex` —
  `audience_matches?("sb", ...)` tightened from an unconditional accept to a
  host-scoped match against the configured endpoint host; loopback endpoints
  additionally accept any loopback audience host (`# KD-COVERS: KD-172`).
- **Standing**: ALIVE
- **Context**: solo

## What changed

`sas_verifier.ex:192` clause replaced (`audience_matches?("sb", _host,
_port, _config), do: true` → host-scope check): an `sb:` audience is
accepted only when its host equals the configured endpoint's host
(case-insensitive), or when both the audience host and the endpoint host
are loopback (`localhost` / `::1` / `[::1]` / `127.*`). Foreign
`sb://<other-host>` now fails `check_audience/2` → typed
`401 INVALID_LOCAL_SAS`.

Wire-compat shape preserved: real SDKs (and `verification/ts/fix4.probe.cjs:80`)
mint the CBS audience from the connection-string namespace —
`sb://127.0.0.1:<port>/<entity>` — same host as the endpoint, so the legit
shape still passes; port remains free (SDKs mint with the real port, and
port is not part of the host-scope check).

## Court (test/internal/kd173r_audience_scope_court_test.exs, real HMAC, no mocks)

```
$ MIX_BUILD_ROOT=_build-kd173r mix test test/internal/kd173r_audience_scope_court_test.exs
Running ExUnit with seed: 418000, max_cases: 32
....
Finished in 0.04 seconds (0.00s async, 0.04s sync)
Result: 4 passed
```

Legs: foreign `sb://` hosts (`foreign-namespace.evil.example`,
`attacker.example`) → typed 401 (the KD-172 hole); legit loopback audiences
(`sb://127.0.0.1:5672`, `sb://127.0.0.1:5672/q`, `sb://localhost:5672/q`,
`sb://localhost/q`) → `{:ok, claims}`; endpoint-host-exact against the
binary endpoint config → ok; foreign non-sb scheme (`amqps://`) → typed 401
(existing control, KD-172 witness row 4).

## Adjacent regression (real SAS/AMQP tests, same tree)

```
$ MIX_BUILD_ROOT=_build-kd173r mix test test/integration/sbkey_boot_config_test.exs \
    test/integration/amqp_kd131_133_triage_test.exs \
    test/integration/store_partition_wire_regression_test.exs \
    test/internal/kd134_requester_delivery_test.exs
Result: 17 passed
```

## Real-SDK non-regression witness (fix4 probe, real handshakes on a live broker)

```
$ MIX_BUILD_ROOT=_build-kd173r SMALT_FIX4_BLOCK=b89 node verification/ts/fix4.probe.cjs
block b89 AMQP 39890 ARM 39892 keybytes 64
PASS kd131.shared-key-at-or-above-32-byte-floor
PASS kd131.cbs-put-token-200-floor-valid-key
PASS kd132b.malformed-body-typed-400
PASS kd132b.connection-survives-after-malformed-body
PASS kd133.spec-ordered-flow-grants-credit-2-deliveries
PASS kd133.topup-flow-delivers-third
TOTAL pass=6 fail=0
exit 0
```

`kd131.cbs-put-token-200-floor-valid-key` is the load-bearing leg: a real
CBS put-token (audience `sb://127.0.0.1:<port>/<entity>`) still verifies
200 on the live broker under `:enforce` after the host-scoping — the
KD-172 close condition's real-SDK arm is satisfied. The KD-172
`fix4.probe.cjs` audience mint (`sb://127.0.0.1:...`) is exactly the
endpoint-host shape the tightened match accepts.

## Disposition

- KD-172 flipped **OPEN → CLOSED-WITH-EVIDENCE** in
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical) with this receipt
  as witness (postdates the shim mtime; flip gated via `scripts/kd_flip.py`
  eligibility, registrar-typed CLOSED-WITH-EVIDENCE per the KD-143
  precedent — a real repair landed in `lib/`, not a simulation shim).
- v26.10.22 pointer register row updated to match.

## Lane hygiene

Tree writes: `lib/smalt/messaging/amqp/sas_verifier.ex`,
`test/internal/kd173r_audience_scope_court_test.exs`, the two register
files, this receipt, and the commit message file. Lane build root
`_build-kd173r` — coordinator delete at integration.
