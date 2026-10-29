# Receipt: BK-AMPSKEP — adversarial skeptic audit, AMQP v1 face (KD-173R scoping + KD-131/132/133)

- **Date**: 2026-10-22
- **Lane**: BK-AMPSKEP (read-only skeptic audit; only this receipt written)
- **Subject**: `lib/smalt/messaging/amqp/sas_verifier.ex` KD-173R host-scoped
  `sb:` audience match + KD-131/132/133 pinned behaviors, re-verified fresh on
  the current tree.
- **Standing**: **PARTIAL_ALIVE** — all pinned behaviors hold fresh; one NEW
  typed finding (F1 below) in the KD-173R scoping itself.
- **Context**: solo

## Leg 1 — KD-173R court re-run fresh

```
$ MIX_BUILD_ROOT=_build-bkampskep mix test test/internal/kd173r_audience_scope_court_test.exs
Running ExUnit with seed: 306807, max_cases: 32
....
Finished in 0.02 seconds (0.00s async, 0.02s sync)
Result: 4 passed
```

Foreign `sb://` hosts → typed 401 INVALID_LOCAL_SAS; loopback audiences
(`sb://127.0.0.1:5672`, `…/q`, `sb://localhost…`) → ok; endpoint-host-exact
against `SasVerifier.endpoint()` → ok; foreign `amqps://` control → typed 401.

## Leg 2 — real fix4 probe, fresh (live broker, :enforce, block b89)

```
$ MIX_BUILD_ROOT=_build-bkampskep SMALT_FIX4_BLOCK=b89 node verification/ts/fix4.probe.cjs
block b89 AMQP 39890 ARM 39892 keybytes 64
PASS kd131.shared-key-at-or-above-32-byte-floor
PASS kd131.cbs-put-token-200-floor-valid-key
PASS kd132b.malformed-body-typed-400
PASS kd132b.connection-survives-after-malformed-body
PASS kd133.spec-ordered-flow-grants-credit-2-deliveries
PASS kd133.topup-flow-delivers-third
TOTAL pass=6 fail=0
EXIT=0
```

The load-bearing leg `kd131.cbs-put-token-200-floor-valid-key` — a real CBS
put-token (audience `sb://127.0.0.1:<port>/<entity>`) still verifies 200 on
the live broker after the host-scoping.

## Leg 3 — adversarial class hunt (new probe, real SasVerifier, real HMAC)

`mix run --no-start` scratch probe (`/tmp/bkampskep_adversarial.exs`), real
`Smalt.Amqp.SasVerifier.verify/2` with tokens HMAC-signed by the real runtime
dev key over each crafted `sr`. Endpoint `%Audience{sb, 127.0.0.1, 5672}`:

```
sb://127.evil.example            =>  OK(200)          <-- F1
sb://127.0.0.1.evil.example      =>  OK(200)          <-- F1
sb://127.1.2.3:9999              =>  OK(200)          (within 127/8 loopback — fine)
sb://[::1]:5672                  =>  OK(200)
sb://[::1]                       =>  OK(200)
sb://::1                         =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://LOCALHOST:5672              =>  OK(200)
sb://localhost.                  =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://localhost:9999              =>  OK(200)          (port free — pinned by design)
sb://127.0.0.1:9999/q            =>  OK(200)          (port free — pinned by design)
sb:// localhost                  =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://localhost%20                =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://0.0.0.0                     =>  REFUSED(401 INVALID_LOCAL_SAS)
sb://foreign.evil.example        =>  REFUSED(401 INVALID_LOCAL_SAS)
amqps://127.0.0.1:5672           =>  REFUSED(401 INVALID_LOCAL_SAS)
```

(F1 rows above are verbatim probe output; the `<--` and parenthetical
annotations are this receipt's, not the probe's. Endpoint
`sb://localhost:5672` binary config: loopback
cross-forms pass, bare `::1` refused; `SasVerifier.endpoint()` =
`"sb://127.0.0.1:5672"`: exact form ok, foreign refused.)

### F1 (NEW, typed) — `loopback_host?` prefix-match accepts attacker-resolvable `127.*` domains

`lib/smalt/messaging/amqp/sas_verifier.ex:215` (`loopback_host?/1`):
`String.starts_with?(h, "127.")` matches any host string starting `127.`,
including attacker-resolvable domains. Verified acceptance:

- `sb://127.evil.example` → `{:ok, _}` under a loopback endpoint
- `sb://127.0.0.1.evil.example` → `{:ok, _}` under a loopback endpoint

Severity bounded: a put-token still needs a valid HMAC over the `sr` minted
with the namespace shared key, so this is a confused-deputy/narrowing defect
(a co-tenant holding the key can mint tokens naming `sb://127.evil.example`
with full namespace rights), not a key-less bypass. Refusals remain typed 401
on every non-matching form.

**Repair ticket (owner: KD-173R repair lane or registrar KD row)**: replace
the `starts_with? "127."` arm with an IP-literal check —
`:inet.parse_address(String.to_charlist(h))` → `{:ok, {127,_,_,_}}` (or exact
`localhost`/`::1`/`[::1]` equality) — so `127.evil.example` and
`127.0.0.1.evil.example` refuse typed 401 while `127.0.0.1` and `127.a`-free
loopback IPs keep verifying. Fix4 probe (`sb://127.0.0.1:...` mint) is the
non-regression gate.

Correctly refused (no finding): bare `::1` (URI.new requires brackets per
RFC 3986 — spec-consistent), trailing dot `localhost.`, whitespace and
percent-encoded whitespace, `0.0.0.0` (unspecified addr), foreign hosts,
foreign scheme. Case-insensitivity works (`LOCALHOST` ok).

## Leg 4 — KD-131/132/133 pinned behaviors re-verified + adjacent suites fresh

```
$ MIX_BUILD_ROOT=_build-bkampskep mix test test/integration/amqp_kd131_133_triage_test.exs \
    test/integration/sbkey_boot_config_test.exs \
    test/integration/store_partition_wire_regression_test.exs \
    test/internal/kd134_requester_delivery_test.exs
Finished in 14.5 seconds (0.00s async, 14.5s sync)
Result: 17 passed
```

```
$ MIX_BUILD_ROOT=_build-bkampskep mix test test/integration/amqp10_adversary_court_test.exs \
    test/integration/amqp10_bk116_skeptic.exs \
    test/integration/amqp10_crash_only_court_test.exs \
    test/integration/amqp10_ledger_owner_court_test_test.exs \
    test/integration/amqp10_skeptic_court.exs
Finished in 187.2 seconds (0.00s async, 187.2s sync)
Result: 25 passed
```

Map32 both-size semantics, malformed-map typed 400 + connection survival, and
spec-ordered flow credit all hold on the current tree (triage court + live
wire both fresh). Wire pinions untouched (SASL ANONYMOUS, 0x44, attach arity,
.NET-GUID, EH partitions).

## Environment disclosure (compile-freeze SLA observed, no lane edits taken)

The shared `lib/` compile broke three times mid-audit under other lanes'
in-flight edits (`confidential_ledger/service.ex`, then `webpubsub/events.ex`
+ `webpubsub/service.ex`, then `attestation/maa.ex`); each recovered within
one 20–30 s bounded poll (owner fixed or reverted). A bare `mix test` with no
file args also refused to compile due to a concurrent lane's in-flight
`test/internal/expl10r_court_test.exs` — not this lane's file; all suites
above were run with explicit file lists and passed as listed.

## Verdict

KD-173R scoping + KD-131/132/133 closures re-witnessed ALIVE on fresh runs;
standings stand. One NEW typed finding **F1** (`loopback_host?/1`
prefix-match, `sas_verifier.ex:215`) with repair ticket above — owner owed a
KD row + repair; `127.evil.example`-class audiences must refuse 401 before
this lane's standing can read full ALIVE.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bkampskep
mix test test/internal/kd173r_audience_scope_court_test.exs   # 4 passed
SMALT_FIX4_BLOCK=b89 node verification/ts/fix4.probe.cjs      # pass=6 fail=0 exit 0
mix test test/integration/amqp_kd131_133_triage_test.exs \
        test/integration/sbkey_boot_config_test.exs \
        test/integration/store_partition_wire_regression_test.exs \
        test/internal/kd134_requester_delivery_test.exs       # 17 passed
mix test test/integration/amqp10_adversary_court_test.exs \
        test/integration/amqp10_bk116_skeptic.exs \
        test/integration/amqp10_crash_only_court_test.exs \
        test/integration/amqp10_ledger_owner_court_test.exs \
        test/integration/amqp10_skeptic_court.exs             # 25 passed
```
