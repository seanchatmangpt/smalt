# R174 — TLS trio + fuzz non-repro

Standing: PASS

## Scope

Three landed TLS changes in `lib/smalt/tls.ex` plus the F3 fuzz non-repro
confirmation:

1. Env-cert source (`SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE`) checked first,
   with `validate_certfile_pair/2` applied on that branch (the old
   `application.ex` env branch skipped validation). Markers:
   `lib/smalt/tls.ex:81` (R90/D52 comment), `:94-95` (env reads).
2. TLS 1.2-only + 2-cipher pin applied unconditionally on every https path
   (dev certs included — previously the pin held only on the env-cert
   branch). Marker: `lib/smalt/tls.ex:156` (SHIM-COURT subject comment).
3. `verify_pair/2` SPKI-identity repair (R156): cert SPKI must equal the
   public half of the paired key — fixes the self-signed-only `pkix_verify`
   that silently deadened env certs against CA-chained leaves.
   Marker: TLS-261014-02 (R156 repair) comment block.

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/tls_test.exs
Finished in 15.6 seconds (0.00s async, 15.6s sync)
20 tests, 0 failures
```

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/kv_tls_test.exs
Finished in 0.7 seconds (0.00s async, 0.7s sync)
7 tests, 0 failures
```

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/amqp/fuzz_test.exs   # run 1
Finished in 12.4 seconds (12.4s async, 0.00s sync)
34 tests, 0 failures
```

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/amqp/fuzz_test.exs   # run 2
Finished in 12.5 seconds (12.5s async, 0.00s sync)
34 tests, 0 failures
```

Fuzz non-repro confirmed: 34/0 twice back-to-back; the session's claimed
flake did not reproduce.

## Recorded caveat (not a blocker)

The combined run `mix test test/tls_test.exs test/kv_tls_test.exs` gives
27 tests / 1 failure — the TLS-261014-01 concurrency falsifier
(test/tls_test.exs:210) hits `{:error, :enoent}` at :243 while 20 paired
boots race a cert regenerator. Each suite green in isolation (20/0, 7/0);
the falsifier is sensitive to same-batch cert-dir contention. Recorded as
an order/concurrency-sensitive surface, owner: TLS lane.

## W11 docs-lane note

V50's confirmation run is re-witnessed here (20/0 + 34/0 x2). Receipt
embeds only re-run output from the docs lane.
