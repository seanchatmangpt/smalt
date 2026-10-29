# KD-157: HTTP/2 twin session instability — root cause + bounded fix

**Standing:** **ROOT-CAUSED — fix landed, live-substrate witness pending restart** (lane law: never restart).

Context: solo

## Cleanup (job 1)

Bulk-deleted the 100 stranded `scvd-t21-mvig2rsb-*` resource groups on the LIVE
substrate via the 9444 twin (STS bearer minted from
`/organizations/oauth2/v2.0/token`, ARM DELETE per RG, ADDED:

```
2026-10-21T18:59:37.340Z total RGs=100 targets=100
2026-10-21T18:59:37.340Z DONE ok=100 notfound=0 err=0
```

100 successes, 0 404s, 0 errors. Script: `tmp/h2twin_cleanup.mjs`.

## Triage (job 2)

Reproduction (live substrate, 128-wide ARM ramp `scripts/bench/scvd_t21_arm_ramp.mjs`):

```
{"lane":"scvd-t21","op":"putgetdelete-c128","n":512,"requests":3072,"transport_retries":539,
 "last_transport_err":"ERR_HTTP2_SESSION_ERROR","errors":0,"standing":"PASS"}
{"lane":"scvd-t21","op":"putgetdelete-c128","n":512,"requests":3072,"transport_retries":562, ...}
```

~17.5–18.3% of requests transport-retried. Three harder runs (768 cycles) later
were clean — burst-dependent.

Which side resets: **the server sends GOAWAY**; node/undici surfaces it as
ERR_HTTP2_SESSION_ERROR on in-flight streams. Server-side witness in
`/tmp/smalt-substrate-state/substrate.log`:

```
[error] ** (Bandit.HTTP2.Errors.ConnectionError) Stream resets rate exceeded 500 resets in 10000ms
```

Mechanism: undici cancels response bodies (`r.body.cancel()`), emitting client
RST_STREAM(CANCEL) in 128-wide bursts; Bandit's default h2
`max_reset_stream_rate {500, 10_000}` counts them and GOAWAYs
ENHANCE_YOUR_CALM (0xB), killing in-flight streams.

Live pre-fix wire witness (raw h2 client, `/tmp/h2burst.exs`, 600 RST burst
against the live 9444 twin):

```
got 35 bytes in 18ms, 3 frames, types=%{4 => 2, 7 => 1}
GOAWAY: [{7, 0, 0, <<0, 0, 3, 29, 0, 0, 0, 11>>}]   # error code 11 = ENHANCE_YOUR_CALM
```

## Diff (minimal)

`lib/smalt/tls.ex` `Smalt.TLS.bandit_opts/2` (both https and http branches,
i.e. 8443 + 9444 seats) now appends
`[http_2_options: [max_reset_stream_rate: {50_000, 10_000}]]` — 100x the
default, still a bounded fail-closed anti-DoS backstop (not a disable); real
front doors do not kill in-flight legit streams over client body-cancels.
`# KD-COVERS: KD-157` in the adjacent comment.

## Chicago test (real transport, no mocks)

`test/integration/h2_reset_rate_parity_test.exs` — raw HTTP/2 client over real
TLS (ALPN h2) built on :ssl, minimal HPACK encoder, real Bandit listeners:

- structural: bandit_opts carries `[http_2_options: [max_reset_stream_rate: {50_000, 10_000}]]` on both branches
- control (non-vacuity): default settings (bandit_opts minus the option) GOAWAY ENHANCE_YOUR_CALM under the same 600-RST burst
- parity: smalt opts take the burst without GOAWAY AND serve a normal END_STREAM request on the same connection afterwards (first body byte 0x7B)

```
$ MIX_BUILD_ROOT=_build-h2twin mix test test/integration/h2_reset_rate_parity_test.exs
3 tests, 0 failures
```

Regression: `mix test test/integration/tls_blob_dispatch_test.exs` → 2 tests, 0 failures.
Sleep-gate: PASS (450 files, 0 unclassified).

## Falsifier (pending, coordinator)

After the next substrate restart (coordinator-owned), rerun
`SCVD_CONCURRENCY=128 node scripts/bench/scvd_t21_arm_ramp.mjs`: transport_retries
must collapse 539–562 → ~0; that receipt flips KD-157 via `scripts/kd_flip.py`.
Live twin still runs pre-fix code (verified: the 600-RST burst still GOAWAYs
against 9444 right now). Clean up the temp witness scripts on flip.

## Machine

```
$ just bench-machine
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

No bench jsonl emitted (triage lane, not a bench lane): the ramp rows above are
the harness's own emissions to `tmp/bench/scvd-arm.jsonl`.
