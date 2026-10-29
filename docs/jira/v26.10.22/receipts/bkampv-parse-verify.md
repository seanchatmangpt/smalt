# Receipt: BK-AMPV — BK-AMPF1 loopback_host? repair, independent read-only verify

- **Date**: 2026-10-22
- **Lane**: BK-AMPV (read-only verify; only this receipt written)
- **Subject**: `lib/smalt/messaging/amqp/sas_verifier.ex` `loopback_host?/1`
  (BK-AMPSKEP F1 repair by BK-AMPF1), re-verified fresh on the current tree.
- **Standing**: **ALIVE**
- **Context**: solo

## Leg 1 — evil-host falsifiers re-run fresh (typed 401 witnessed)

Real `Smalt.Amqp.SasVerifier.verify/2`, real HMAC minted with the real
runtime dev key, endpoint `%Audience{scheme: "sb", host: "127.0.0.1", port: 5672}`:

```
sb://127.evil.example                =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://127.0.0.1.evil.example          =>  REFUSED(401 INVALID_LOCAL_SAS)
```

Both F1 probes still flip to typed 401; the prefix-match hole stays closed.

## Leg 2 — clean-form inventory from the audit, all hold

```
sb://127.0.0.1:5672                  =>  OK(200)
sb://127.0.0.1:9999                  =>  OK(200)
sb://LOCALHOST:5672                  =>  OK(200)
sb://localhost:9999/q                =>  OK(200)
sb://[::1]:5672                      =>  underlying loopback, exact-list match — OK(200)
sb://[::1]                           =>  OK(200)
sb://127.1.2.3:9999                  =>  OK(200)   (127/8 dotted-quad posture)
amqps://127.0.0.1:5672               =>  REFUSED(401 INVALID_LOCAL_SAS)  (scheme control)
```

Every no-finding form from the audit keeps its prior verdict.

## Leg 3 — NEW adversarial shapes vs :inet.parse_address (typed verdicts)

| sr audience | verdict | classification |
|---|---|---|
| `sb://127.0.0.1:5672@evil.example` | REFUSED(401 INVALID_LOCAL_SAS) | refused (userinfo/host split) |
| `sb://evil.example:5672:5672` | REFUSED(401 INVALID_LOCAL_SAS) | refused (malformed host) |
| `sb://0177.0.0.1` | OK(200) | **accepted-with-reason**: `inet:parse_address` implements inet_aton semantics — `0177.0.0.1` parses to `{127,0,0,1}` (witnessed: `{ok,{127,0,0,1}}`) |
| `sb://0x7f.0.0.1` | OK(200) | **accepted-with-reason**: same inet_aton class, hex octet → `{127,0,0,1}` |
| `sb://127.1` | OK(200) | **accepted-with-reason**: BSD short form → `{127,0,0,1}` |
| `sb://2130706433` | OK(200) | **accepted-with-reason**: 32-bit integer form → `{127,0,0,1}` |
| `sb://::ffff:127.0.0.1` | REFUSED(401 INVALID_LOCAL_SAS) | refused (bare IPv6 w/ colons fails URI.new host shape) |
| `sb://[::ffff:127.0.0.1]:5672` | REFUSED(401 INVALID_LOCAL_SAS) | refused fail-closed: parses `{0,0,0,0,0,65535,32512,1}` — not `{127,_,_,_}`, not in the exact list |
| `sb://%31%32%37.0.0.1` | OK(200) | **accepted-with-reason**: `check_audience/2` URI-decodes `sr` before matching (spec: sr is URL-encoded; signing already uses encoded sr), decodes to the loopback literal |
| `sb://127.0.0.1␣` (trailing ws) | REFUSED(401) | refused (`{error,einval}` at parse_address — witnessed directly) |
| `sb://␣127.0.0.1` (leading ws) | REFUSED(401) | refused (einval) |
| `sb://127.0.0.1.` (trailing dot) | REFUSED(401) | refused (einval) |
| `sb://[127.0.0.1]` | REFUSED(401) | refused (einval — brackets are IPv6 form) |
| `sb://localhost.` | REFUSED(401) | refused (exact-list miss) |
| `sb://0.0.0.0` | REFUSED(401) | refused (unspecified addr) |

Verbatim probe output:

```
== LEG1 evil-host falsifiers (expect typed 401) ==
sb://127.evil.example                =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://127.0.0.1.evil.example          =>  REFUSED(401 INVALID_LOCAL_SAS)
```

Full LEG2/LEG3 table embedded above; probe file `/tmp/bkampv_probe.exs`
(`mix run --no-start`, real SasVerifier + real runtime dev key, no mocks).

### Honest classification of the inet_aton-family accepts

`0177.0.0.1`, `0x7f.0.0.1`, `127.1`, `2130706433` are **genuine loopback
address literals** under Erlang/OTP `inet:parse_address` (inet_aton)
semantics — each witnesses `{ok,{127,0,0,1}}`, the same loopback address as
`127.0.0.1`, and none is an attacker-resolvable hostname (an address literal
never consults DNS). So acceptance preserves the loopback posture and does
NOT reopen F1. Hardening note (not a defect): if strict dotted-quad-only
were desired, `loopback_ipv4?/1` would need a shape guard
(4 dot-separated decimal octets, no `0x`/short/integer forms) — fail-open
surface unchanged: every accepted form is still the loopback address itself.

`[::ffff:127.0.0.1]` (IPv4-mapped IPv6 loopback) is refused fail-closed —
it parses to a non-127 IPv6 tuple. Semantically it IS loopback, so this is
a (safe-direction) false negative, not a hole.

## Leg 4 — court + real-SDK probe fresh

```
$ MIX_BUILD_ROOT=_build-bkampv mix test test/internal/kd173r_audience_scope_court_test.exs
Running ExUnit with seed: 993266, max_cases: 32
......
Finished in 0.05 seconds (0.00s async, 0.05s sync)
Result: 6 passed
```

(fresh seed, includes the two F1 falsifier legs + 127/8 posture + clean forms)

```
$ MIX_BUILD_ROOT=_build-bkampv SMALT_FIX4_BLOCK=v72 node verification/ts/fix4.probe.cjs
block v72 AMQP 40420 ARM 40422 keybytes 64
PASS kd131.shared-key-at-or-above-32-byte-floor
PASS kd131.cbs-put-token-200-floor-valid-key
PASS kd132b.malformed-body-typed-400
PASS kd132b.connection-survives-after-malformed-body
PASS kd133.spec-ordered-flow-grants-credit-2-deliveries
PASS kd133.topup-flow-delivers-third
TOTAL pass=6 fail=0
EXIT=0
```

(real broker boot on fresh block v72 per the port law — blocks match
`^([bcv])(\d+)$`; prior receipts used b89/c81, this lane used v72. The
load-bearing leg `kd131.cbs-put-token-200-floor-valid-key` re-witnesses the
SAS surface end to end on the live broker.)

Adjacent regression suites:

```
$ MIX_BUILD_ROOT=_build-bkampv mix test test/integration/amqp_kd131_133_triage_test.exs \
    test/integration/sbkey_boot_config_test.exs \
    test/internal/kd134_requester_delivery_test.exs
Result: 11 passed
```

## Verdict

The BK-AMPF1 repair holds under the new shapes: both evil-host falsifiers
refuse typed 401, the full audit clean-form inventory keeps its verdicts,
and every newly probed adversarial shape gets a typed verdict — the only
accepts are genuine loopback address literals under inet_aton semantics
(same address `{127,0,0,1}`), none attacker-resolvable. No F1-class hole
reopened; `[::ffff:127.0.0.1]`-class IPv4-mapped forms refuse fail-closed.
Standing **ALIVE**.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bkampv
mix test test/internal/kd173r_audience_scope_court_test.exs   # 6 passed
SMALT_FIX4_BLOCK=v72 node verification/ts/fix4.probe.cjs      # pass=6 fail=0, exit 0
mix test test/integration/amqp_kd131_133_triage_test.exs \
        test/integration/sbkey_boot_config_test.exs \
        test/internal/kd134_requester_delivery_test.exs       # 11 passed
mix run --no-start /tmp/bkampv_probe.exs                      # LEG1-3 tables above
```
