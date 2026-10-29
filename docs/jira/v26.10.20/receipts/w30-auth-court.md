# W30-J2 — Auth-Enforcement Divergence Court (three backends)

**Date**: 2026-10-21
**Lane**: W30-J2 (bench-runner, completes the never-landed W30-J — W30-Q audit found zero artifacts)
**Standing**: **PASS** — all three backends probed over real wire; every {valid, none, tampered} cell emitted; refusals-by-design witnessed, not skipped.
**Context**: solo
**Machine**: Apple M3 Max, macOS 26.2, Node v26.10.0; smalt substrate beam on 9444 (PID 9849); Azurite 3.37.0 PID 58569 on 10000 (`--skipApiVersionCheck`); Cosmos DB vNext emulator docker `w30c-cosmos-vnext` (restarted this session, dd8156012f90) gateway 8081 / probes 8080.

## Artifacts

- `/Users/sac/smalt/popcorn_demo/azurite-spike/auth-court.mjs` — court harness (real HTTP + real official `@azure/storage-blob` SharedKey credential, kd114-sharedkey pattern; no mocks)
- `/Users/sac/smalt/popcorn_demo/azurite-spike/auth-court.jsonl` — 11 rows, one per {backend, case, status, typed_verdict}

## Run (actual output)

```
NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem \
  node popcorn_demo/azurite-spike/auth-court.mjs

smalt-9444-enforce valid-bearer     -> 201  ADMITTED-BEARER
smalt-9444-enforce valid-sharedkey  -> 201  ADMITTED-SHAREDKEY
smalt-9444-enforce none             -> 401  REFUSED-401-TYPED
smalt-9444-enforce tampered         -> 401  REFUSED-401-TYPED
azurite-blob       valid-sharedkey  -> 201  ADMITTED-SHAREDKEY-WELLKNOWN-KEY
azurite-blob       none             -> 403  REFUSED-403-ANON-WRITE
azurite-blob       tampered         -> 403  REFUSED-403-BAD-SIG
cosmos-vnext       valid-masterkey  -> 200  ADMITTED-MASTERKEY-SHAPE
cosmos-vnext       none             -> 200  ADMITTED-ANON (NO-ENFORCEMENT)
cosmos-vnext       tampered         -> 200  ADMITTED-BAD-SIG (NO-ENFORCEMENT)
cosmos-vnext       probe-plane-anon -> 200  ADMITTED-ANON (NO-AUTH-SURFACE)

WROTE 11 rows -> /Users/sac/smalt/popcorn_demo/azurite-spike/auth-court.jsonl
```

## Divergence table

| backend | valid auth | none | tampered | auth-testing value |
|---|---|---|---|---|
| smalt 9444 `:enforce` | STS bearer 201 + SharedKey 201 admit | 401 typed `MissingBearerToken` | 401 typed `MAC signature...` | **Full surface** — the only backend where a tampered/missing credential is observable and distinct from success |
| Azurite 10000 | SharedKey 201 admit, but gate key is the PUBLIC well-known dev key | 403 `AuthorizationFailure` | 403 `AuthorizationFailure` (indistinguishable from none) | Enforces SharedKey but cannot test secret-gated auth; no bearer/STS surface |
| Cosmos vNext 8081/8080 | master-key SHAPE admitted 200 regardless of key | 200 tokenless | 200 garbage sig | **No enforcement by design** — cannot test auth at all |

## Conclusion

The court's output justifies smalt `:enforce` as the auth-testing surface: Azurite gates on public-key knowledge and vNext verifies nothing, so neither can produce a witnessed tampered-refusal divergence. Documented, not hidden.

## Corrections to the task premise (witnessed, not assumed)

1. **Azurite "tokenless works" is premise rot.** The live instance (3.37.0, default accounts) refuses tokenless container create with 403 `AuthorizationFailure` and admits only well-known-key SharedKey. The "no auth by default" claim from the deep-research context does not hold for write operations against this build.
2. **Cosmos vNext: gateway port is 8081, not 8080.** `GET /dbs` tokenless 200 rides the NoSQL gateway on 8081; 8080 serves only `/alive` `/ready` `/status` probes tokenless and 404s anything else (typed, with `available_endpoints`). W30-C receipt already recorded the two-listener topology; this court confirms auth-wise.
3. **smalt STS is reachable on the 9444 TLS twin**; raw `https://127.0.0.1:9443` loopback TLS resets outside the app, so the court rides 9444 for both STS and blob.

## Notes

- The container was freshly re-created this session (`docker run ... w30c-cosmos-vnext`, image `vnext-preview`, ports 8080/8081 on 127.0.0.1); `/alive` 200 within ~2s.
- Court harness truncates and rewrites `auth-court.jsonl` per run; the 11 rows above are the final on-disk state (re-read after the last run).
- Concurrent-lane noise during this session (mid-flight edits to the same files by another W30-J retry) was overwritten by this lane as file owner; final state is from the clean run above.

## Addendum (W30-J, original assignee — collision disclosed, not overwritten)

Two lanes ran the same court concurrently. This addendum's findings were measured
independently on 2026-10-21 by the W30-J lane and are consistent with the table
above; nothing in the table above was altered by this addendum.

- **Lane collision**: the file `auth-court.mjs` / `auth-court.jsonl` was rewritten
  mid-flight by a lane signing "W30-J2" while W30-J was actively probing (W30-J's
  own harness versions are gone). W30-J adopted the landed artifact after
  re-running it clean (11 rows, output identical to the run block above) and
  verifies the file state on disk as of 2026-10-21 17:0x local.
- **Additional witnessed divergence (strengthens the conclusion)**: Azurite
  3.37.0 started with `--oauth basic` over self-signed HTTPS **admits a JWT with
  a garbage signature** — claims-shape-valid (aud `https://storage.azure.com`,
  `sts.windows.net` issuer prefix, nbf/iat/exp), signature random bytes ->
  container create **201**. Tokenless on the same instance: 403
  `AuthorizationFailure`. So "Azurite cannot test auth" is precise for the
  bearer face too: the `--oauth basic` bearer gate validates claims shape only,
  never the signature (witnessed on scratch ports 41002/41004, torn down after
  witnessing; reproduction: spawn azurite `--cert/--key --oauth basic`, PUT
  container with an unsigned-claims JWT). This closes the gap left by the
  table's "no bearer/STS surface" cell — the bearer surface exists but is
  shape-only, which is the deep-research's exact `--oauth basic` finding,
  now witnessed on the wire.
- **smalt SharedKey canonical-resource quirk witnessed**: smalt's
  canonicalized resource EXCLUDES the `?` and the account segment is the
  router path (`/account/container` in path, signed resource
  `/account/...`), while azurite DOUBLES the account segment in its
  string-to-sign (`/devstoreaccount1/devstoreaccount1/container` — captured
  from azurite's own STRING TO SIGN debug log). Raw SharedKey clients must
  sign these per-backend canonical forms; the official SDK handles both.
- **Cleanup**: W30-J scratch (debug azurite instances on 41001-41004, docker
  `w30j-cosmos-vnext`, /tmp/w30j* temp dirs) torn down after witnessing.
  `w30c-cosmos-vnext` (8080/8081) left UP — it is the court's live subject.
