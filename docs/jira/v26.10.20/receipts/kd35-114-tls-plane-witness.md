# W13-D — KD-35/KD-114: blob face on the TLS twin (dispatch flip) — witness receipt

**Standing:** PARTIAL_ALIVE

- Date: 2026-10-20
- Lane: W13-D (writer, v26.10.20)
- Subject: /Users/sac/smalt @ main 934d21a (uncommitted lane diff — see Diff)
- Files this lane touched: `lib/smalt/application.ex`,
  `test/integration/tls_blob_dispatch_test.exs` (new), this receipt (new).
  Other dirty paths in the tree belong to concurrent lanes — not this diff.

## What changed (the KD-114 redesign core)

`Smalt.Application.TlsTwinDispatch.call/2` flipped its default arm: unknown
non-ARM paths on the https://127.0.0.1:9444 twin now route to
`Smalt.EgressRouter` instead of `ArmGateway.Router`. The storage catch-all
family (blob `/{account}/{container}/{blob}`, queue plane, Files plane) lives on
arbitrary account-shaped paths — no enumerable prefix can name them — so the
dispatch inverts:

- `@egress_prefixes` wins first (unchanged behavior, KD-117 lineage intact).
- New `@arm_only_prefixes` names the ARM-exclusive top-levels on the twin:
  `/subscriptions`, `/tagNames`, `/tenants`, `/metadata/identity`, `/oauth2`
  (every ARM route is /subscriptions-scoped or one of these).
- Tenant-scoped STS (`POST /:tenant/oauth2/v2.0/token`) is caught by a
  `String.contains?(path, "/oauth2/")` branch → ARM.
- Default arm flips to EgressRouter → storage catch-all served with the same
  handler engine as http 8443, byte-identical requests.
- `# KD-COVERS: KD-114` marker rides the cond in `lib/smalt/application.ex`.

Diff (functional lines only, `git diff lib/smalt/application.ex`): the
`if/else` in `TlsTwinDispatch.call/2` replaced by a 4-arm `cond` + the
`@arm_only_prefixes` attribute + the comment block replacing the "blob catch-all
out of scope for the TLS twin" note. No behavioral change outside the twin
dispatch; children-list indentation is the only other delta (whitespace).

## Witness (real transport, no mocks)

`MIX_BUILD_ROOT=_build-w13d mix test test/integration/tls_blob_dispatch_test.exs
test/integration/deletedkeys_purge_route_test.exs` — **3 tests, 0 failures**.
Real HTTPS over the real twin listener (Bandit + TlsTwinDispatch, ephemeral
`arm_tls_port`), real curl subprocess with `--cacert` pinned to the listener's
actual dev cert, bearer challenge dance on 401 (KD-15 disjunctive: tokenless
probe → 401 → real STS `POST /organizations/oauth2/v2.0/token` → resend). Wire
transcript:

```
PUT  /w13dlane/cont-1792557000638              -> Sent 201 (container create)
PUT  /w13dlane/cont-.../blob-...txt            -> Sent 201   (KD-114 flip)
GET  /w13dlane/cont-.../blob-...txt            -> Sent 200 (byte-equal body)
GET  /w13dlane/cont-.../absent.txt             -> Sent 404 BlobNotFound (storage-shaped, not ARM JSON)
GET  /subscriptions/00000000-...000000         -> Sent 200 Sovereign Smalt Subscription (ARM control leg)
POST /organizations/oauth2/v2.0/token          -> 200 access_token (STS control leg)
GET  /deletedkeys/w3e-purge-...                -> 200 / 204 / 404 (pre-existing KD-117 twin leg, no regression)
```

KD-35 posture witnessed: bearer-bearing planes ride the twin — the storage face
now answers under the same enforce-mode bearer challenge as KV/ARM.

## Cross-lane disclosure (compile-freeze law)

A concurrent lane added a KD-51 branch inside this file's `TlsTwinDispatch`
cond (`String.contains?(conn.query_string, "api-version=") -> ArmGateway.Router`
— SB ATOM management URL space, lib/smalt/application.ex:187-194) after the
W13-D cond landed. Verified post-merge: `mix compile` 0 warnings for
application.ex + the 3-test witness suite still 3/0 green. Disclosed in BOTH
lanes' receipts per the fan-out law.

## What remains HEAVY (honest gaps)

1. **9444 substrate witness — BLOCKED for this lane by instruction.** The
   standing substrate beam (pid 62236, LISTEN 127.0.0.1:9444) predates the
   flip: a live `curl -sk -X PUT ... https://127.0.0.1:9444/...` answers 401
   through the OLD dispatch. The new code needs a substrate restart, which the
   lane is NOT authorized to perform. **Coordinator: restart the substrate
   (scripts/substrate.sh) to land the live-witness leg**, then the flip is
   re-witnessable on 9444 in one curl.
2. **SharedKey-admit leg (KD-114 falsifier proper)**: real-SDK BlobClient
   upload → list → download byte-equal under enforce auth via SAS. The twin
   dispatch now makes it ROUTABLE but the SharedKey/SAS admit path on the twin
   seat is unexercised here — stays registered HEAVY in KD-114 until
   `just sdk-ts` blob cell runs GREEN over https.
3. KD row flips (KD-114/KD-35) are receipt-gated via `scripts/kd_flip.py
   --apply` and belong to the registrar after legs 1+2 land; this lane does not
   flip rows.

## Reproduce

```
MIX_BUILD_ROOT=_build-w13d mix test test/integration/tls_blob_dispatch_test.exs
```
