# Receipt: AMQPT lane — KD-131 / KD-132 / KD-133 triage

- **Date**: 2026-10-21
- **Lane**: AMQPT (writer), repo `/Users/sac/smalt`
- **Build root**: `MIX_BUILD_ROOT=_build-amqpt` (lane lease; coordinator deletes at integration)
- **Subject**: `lib/smalt/messaging/amqp/**` at main ccb575b (plus in-flight working tree)
- **Context**: solo
- **Standing (lane)**: ALIVE — all tests pass; no shared-substrate transition performed.

## Verdicts

| KD | Verdict | Mechanism |
|---|---|---|
| KD-131 | **ROOT-CAUSED** (fix lives outside lane ownership) | Boot path is already cured at source: `scripts/substrate.sh:200-210` now derives a 44-byte per-host key (`base64(sha256(hostname+"smalt-dev-sb"))`), warns on unset `SMALT_SB_SHARED_KEY` and honors `SMALT_FAIL_ON_DEFAULT_SB_KEY` refuse. `SasVerifier.shared_key/0` floor (`@min_key_bytes 32`) honored. Remaining to close: a CBS put-token 200 wire witness on the SHARED plane (canonical ports) — out of lane scope (shared substrate untouched per lane law). |
| KD-132 | **FIXED** (shim predated lane; falsifier court landed this lane) | `KD-COVERS: KD-132` markers already present: `connection.ex:1674` (handle_cbs %{} normalization → typed 400 UNSUPPORTED_CBS_REQUEST, connection survives) and `connection.ex:1976`. Codec map32 decodes at BOTH size semantics. This lane's tests are the witness postdating the shim (the kd_flip precondition). |
| KD-133 | **FIXED** (mtime-cured) | `frame_codec.ex:125-137` `@composite_fields` flow order IS the AMQP 1.0 spec order (next_incoming_id, incoming_window, next_outgoing_id, outgoing_window, handle, delivery_count, link_credit, available, drain, echo, properties); `connection.ex:562-571` credit semantics are rhea-aligned (absolute snapshot `credit = flow.delivery_count + flow.link_credit - delivery_count`). The KD row's "spec-ordered flows grant zero credit" is NOT observable on current code — witnessed live on the wire. |

## Falsifier court (new): `test/integration/amqp_kd131_133_triage_test.exs`

Chicago discipline: real PrimitiveCodec byte round-trips, real SasVerifier HMAC,
real TCP socket + real Connection GenServer + real QueueStore. No mocks.

```
$ MIX_BUILD_ROOT=_build-amqpt mix test test/integration/amqp_kd131_133_triage_test.exs
7 tests, 0 failures
```

Faces covered:

- **KD-132a** map32 (0xD1): element-count (rhea form, encoder-emitted, body >255B forces 0xD1), pair-count (spec-literal, hand-built), malformed odd-item map → typed `{:error, :invalid_length}`, never raises.
- **KD-131** verifier face: configured ≥32-byte key honored end-to-end (`shared_key/0` returns it; token minted from it passes the REAL `verify/2`); sub-floor 12-byte `"ws8sharedkey"` configured key refused → generated-key fallback (mechanism typed).
- **KD-132b** wire face: raw malformed map32 application-properties on a real `$cbs` transfer → broker answers typed `400 UNSUPPORTED_CBS_REQUEST` (observed in log), connection process stays ALIVE, and the same connection still completes a valid CBS put-token 200 and a credited receiver delivery afterward.
- **KD-133** wire face: SPEC-ordered flow (all 7 fields, spec order) grants credit on the live broker — delivery arrives, no starvation.

## Adjacent AMQP tier (existing)

```
$ MIX_BUILD_ROOT=_build-amqpt mix test test/integration/kd143_rules_persistence_test.exs \
    test/internal/kd134_requester_delivery_test.exs test/integration/queue_message_ct_test.exs \
    test/sb_topic_fanout_test.exs
15 tests, 0 failures
```

3 consecutive green reruns. **Honest failure disclosure**: run 1 of this suite (before
stability reruns) reported `15 tests, 1 failure` with output truncated before the test
name was captured; it did not reproduce in 4 subsequent full runs (15/0 x4). Typed as
UNREPRODUCED-SINGLE-RUN, not silently dropped. A dedicated flake hunt is a follow-up,
not this lane's diff (no lib/ changes were made by this lane).

## KD-131 close path (outside lane ownership)

1. `scripts/substrate.sh` boot env already carries the ≥32-byte per-host key (code-read
   evidence, lines 200-210) — no lib/ fix required.
2. `scripts/dev_env.sh:27` comment still names the historical 12-byte `"ws8sharedkey"`
   fallback — doc-only residue, safe to drop by the scripts owner.
3. To flip the row (`scripts/kd_flip.py --apply`), the close condition stands: a real
   CBS put-token 200 on the SHARED plane at canonical ports, receipt postdating this one.

## Machine context

`just bench-machine` was not required (no bench lane run; this is a triage court, not a
perf lane). Machine: Apple Silicon Darwin 25.2.0, OTP 1.19.5/Elixir stack per repo doctor.

## Standing

**Standing:** ALIVE (KD-132/KD-133 witnessed FIXED on current code; KD-131 ROOT-CAUSED, open pending the shared-plane wire witness)

- KD-132, KD-133: ALIVE-witnessed as FIXED on current code; ready for `kd_flip.py --apply`
  once the register owner runs it (this lane does not flip rows).
- KD-131: ROOT-CAUSED, OPEN in the register until the shared-plane wire witness lands.
