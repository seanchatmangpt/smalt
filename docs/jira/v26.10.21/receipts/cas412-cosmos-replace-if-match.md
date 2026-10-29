# CAS412 — cosmos replace-path If-Match: divergence root-caused SDK-side; wire surface correct; stale 412 now etag-carrying

**Standing: ALIVE** — the HIGH divergence in PB-1's DIV-1
(`docs/jira/v26.10.21/receipts/pb1-fond-loop-latency.md`) does NOT reproduce as a
server divergence. The cosmos HTTP wire surface honors If-Match on replace
(800/800 stale-`If-Match` replaces answered 412 PreconditionFailed through the real
@azure/cosmos 4.10.1 over the lane-b1 TLS twin). PB-1's 1700/1700 "accepted" witness
was an SDK-side no-op option: `ifMatchEtag` appears ZERO times in the @azure/cosmos
4.10.1 dist — the option is silently swallowed, no If-Match header is ever sent, and
the server correctly answers last-writer-wins 200. The wire-If-Match gap PB-1
dispatched this lane to close is **premise rot**, not a wire defect.

- Date: 2026-10-21 · Lane: CAS412 (writer, OTP-29) · Context: full
- Repo: /Users/sac/smalt (branch main, tree shared with concurrent lanes)
- Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}`
  (`just bench-machine`)
- Toolchain: Elixir 1.20.4-otp-29, MIX_BUILD_ROOT=_build-cas412, MIX_ENV=test

## Diff (lane-owned)

- `lib/smalt/data_plane/cosmos.ex` — do_put_doc stale arm: 412 now carries the
  CURRENT etag in the `ETag` response header (Azure envelope body unchanged):
  {:ok, 412, success_headers(db, coll, current_lsn(db, coll), %{"etag" => existing["_etag"]}),
   %{"code" => "PreconditionFailed", "message" => precondition_message()}}
- `test/integration/kd_conformance_test.exs` — new Chicago court
  "CAS412: cosmos replace honors If-Match (200/412/unconditional)":
  matching etag → 200 + fresh quoted-GUID etag (KD-148 shape, rotates);
  stale etag → 412 + `code == "PreconditionFailed"` + ETag response header
  == current etag; absent If-Match → 200 unconditional replace, body IS
  the stored doc (replace-not-merge).

No route change was needed in `lib/smalt/egress/CosmosRoutes.ex`: the PUT doc route
passes the full header map through and `Smalt.DataPlane.Cosmos.put_doc/5` already
CASes on If-Match (Store.compare_and_swap). The task premise ("route has no if-match
arm") was false on the current tree.

## Before/after wire (real HTTP, Smalt.EgressRouter, MIX_ENV=test probe)

Identical before/after for all three arms except the 412's ETag header (added):

- `PUT .../docs/d1` + `if-match: "<current>"` → 200, body `_etag` fresh quoted GUID
  (e.g. `"634e5a6e-…"`), rotates every replace.
- `PUT .../docs/d1` + `if-match: "<stale>"` → **412 PreconditionFailed**, Azure
  envelope; post-edit the response carries `ETag: "<current quoted GUID>"`.
- `PUT .../docs/d1` no If-Match → 200, unconditional replace.

## SDK isolation (the load-bearing evidence)

Raw fetch PUT to the lane-b1 twin (39014) with explicit `if-match: bogus` +
`x-ms-documentdb-partitionkey` → **412** (server honors If-Match over the twin).
Same twin, SDK `item.replace(body, { ifMatchEtag: "bogus" })` → **200 accepted**.
`grep -r ifMatchEtag verification/ts/node_modules/@azure/cosmos/dist` → 0 hits;
`dist/commonjs/request/request.js:85-86` shows the actual mechanism:
`options.accessCondition.type === "IfMatch"` → `If-Match` header.

## SDK contention re-witness (20 waves, r=10, fanout 4, high injection)

Driver `/tmp/cas412_sdk_leg.sh` (bench_boot b1, twin 39014, cert
tmp/dev-certs/dev-cert-39014.pem), probe `/tmp/cas412_sdk_probe.mjs`, stdout-only —
no bench jsonl emitted (not a registered lane; PB-1's result file untouched).

- With `ifMatchEtag` (PB-1's shape): **800 stale attempts, 77+ accepted with 200,
  conflicts_412 = 0** — PB-1's DIV-1 witness reproduces exactly, explained by the
  SDK no-op option.
- With `accessCondition: { type: "IfMatch", condition: etag }` (the real SDK
  mechanism): **conflicts_412 = 800/800, injection_failures = 0, unexpected_errors
  = 0**, 80/80 sampled 412s carried the current etag in the response headers;
  p50 22.438 ms, p95 24.302 ms, p99 35.066 ms per wave (4 docs × 10 forced CAS
  retries + read-backs over TLS loopback, default SDK retry policy active).
  The SDK's 412-facing path (recovery via read-back then CAS match) engaged on
  every settlement — 20/20 waves clean.

## Courts (commands + output)

- kd_conformance tier: `MIX_ENV=test MIX_BUILD_ROOT=_build-cas412 mix test
  test/integration/kd_conformance_test.exs` → `6 passed` (incl. new CAS412 court).
- Cosmos tier: `mix test test/data_plane test/integration/kd_conformance_test.exs
  test/integration/cosmos404_typed_error_test.exs
  test/internal/cosmos_kd65_scripts_test.exs
  test/internal/cosmos_analytical_ttl_test.exs` → `69 passed`.
- Errors field honesty: both tiers 0 failures, 0 skips.

## KD recommendation (registrar owns the register)

The gap PB-1 saw predates no server closure — the server never had the gap. Recommend
a KD row (next free number) in the active window's KNOWN_DIVERGENCES.md, roughly:

- Surface: cosmos docs replace, @azure/cosmos 4.10.1.
- Divergence: SDK RequestOptions.ifMatchEtag is a silent no-op in 4.10.1 —
  optimistic CAS via item.replace requires `accessCondition: { type: "IfMatch",
  condition: etag }`; ifMatchEtag-bearing replaces never send If-Match and the
  (correct) server answers LWW 200. PB-1's DIV-1 (1700/1700 accepted) was this
  no-op, not a wire divergence.
- Evidence receipt: this file.
- Close condition: none server-side needed; closes as SDK-usage parity note if
  the verification/ts probes standardize on accessCondition.

Also note: the emulator's 412 now carries the current etag in the ETag header
(Azure's real service does not do this — it is an emulator affordance per DIV-1's
close condition; flag to registrar whether it warrants its own divergence row).

## Session-introduced tree state (disclosure)

- Trunk was transiently build-broken mid-session (amqp10/frame_decoder.ex mid-write
  by its owning lane); resolved by the owner within the SLA — this lane polled and
  did not touch the file.
- Lane build root `_build-cas412` left in place for reuse; coordinator may reclaim
  via lane-clean at integration.
