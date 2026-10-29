# W30-G — Dual-mode blob witness (testing-9 shape)

**Standing:** PARTIAL_ALIVE — azurite leg 5/5 PASS, smalt leg 4/5 with one typed divergence (delete refused 409 by smalt's WORM-by-default container policy). Same suite file, zero assertion changes between runs.

- Suite: `/Users/sac/smalt/popcorn_demo/azurite-spike/dual-mode-test.mjs`
  sha256 `3bfdcd8491c3b85252b64699e216760ac0745e894639037655175abf4377e401` (identical file for both runs)
- Machine (just bench-machine): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- Backends: smalt TLS twin `https://127.0.0.1:9444/popcorn` (SharedKey account `popcorn`,
  key `base64(sha256(account+"smalt-dev-sb"))`, per kd114-sharedkey.probe.cjs);
  azurite `http://127.0.0.1:10000/devstoreaccount1` (devstoreaccount1 well-known dev key),
  started with `--skipApiVersionCheck` (SDK api-version 2026-10-06 rejected otherwise).
  Azurite left listening on 127.0.0.1:10000 (PID 58569) for other W30 lanes.

## Verbatim runs (final paired run)

### RUN 1: `NODE_EXTRA_CA_CERTS=../../.smalt/tls/ca-cert.pem BACKEND=smalt node dual-mode-test.mjs`

```
[backend] smalt endpoint=https://127.0.0.1:9444/popcorn
PASS dual.container-create.201
PASS dual.put.2xx
PASS dual.list.includes-blob
PASS dual.get.byte-equal
FATAL backend=smalt Blob modification refused: container policy enforces immutable WORM retention. statusCode=409
exit=1
```

### RUN 2: `BACKEND=azurite node dual-mode-test.mjs`

```
[backend] azurite endpoint=http://127.0.0.1:10000/devstoreaccount1
PASS dual.container-create.201
PASS dual.put.2xx
PASS dual.list.includes-blob
PASS dual.get.byte-equal
PASS dual.delete.2xx
SUMMARY backend=azurite pass=5 fail=0
exit=0
```

## Divergence found (candidate KD row — not minted, per GAP-token law)

smalt refuses `Delete Blob` with `409 ContainerLocked` ("container policy enforces
immutable WORM retention") on ANY container created over HTTP: HTTP Put Container
defaults `immutable=true` with `retention_days=1095`
(`lib/smalt/data_plane/blob_storage.ex:157`, `egress_router.ex:1053`), and
`worm_blocked?/3`'s delete arm blocks while `immutable==true and not policy_present?`
(`blob_storage.ex:2076`). The official SDK has no wire way to create a mutable
container (the `x-ms-immutable-policy: false` escape hatch is not an SDK-sendable
header), so via the official SDK the delete step can never succeed against smalt.
Azurite matches real Azure (delete succeeds on a default container). smalt's
WORM-by-default is pinned behavior (blob-worm invariant gate), so the close
condition for this divergence is a KD row, not a lib/ change. No row exists in
`docs/jira/v26.10.20/KNOWN_DIVERGENCES.md` as of this receipt — flagged for the
KD registrar.

## Notes

- One pre-run fix before either leg counted: the service URL was corrected to
  include the account path (`base + "/" + account`) after the very first smalt
  attempt hit `404 No route matches PUT /w30g-container-...`; assertion code was
  never touched between runs.
- azurite leg needed `--skipApiVersionCheck`; without it the leg FATALs with 400
  API-version-not-supported (this run's harness/config fix, not an assertion change).
