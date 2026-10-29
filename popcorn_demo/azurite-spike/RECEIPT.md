# RECEIPT — W30-A smalt/Azurite blob-face interop spike

- Repo: /Users/sac/smalt (canonical checkout, no git ops)
- Date: 2026-10-21
- Subject: `popcorn_demo/azurite-spike/` (probe.mjs, package.json, this receipt)
- Backends: smalt TLS twin `https://127.0.0.1:9444` (account `popcorn`,
  SharedKey per `verification/ts/kd114-sharedkey.probe.cjs`), Azurite 3.37.0
  blob-only on `http://127.0.0.1:10100/devstoreaccount1` (started
  `npx azurite-blob --location ./azdata --blobPort 10100 --skipApiVersionCheck`)
- SDK: @azure/storage-blob 12.34.0 (same client instance shape both legs)
- Machine: {"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
- Full output: `probe-out.json` (same dir)

## Command

```
cd /Users/sac/smalt/popcorn_demo/azurite-spike && \
NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem node probe.mjs
```

## Interop table (operation | smalt | azurite | match?)

| operation        | smalt (127.0.0.1:9444)                        | azurite (10100) | match? |
|------------------|-----------------------------------------------|-----------------|--------|
| container-create | 201                                           | 201             | YES    |
| blob-put         | 201                                           | 201             | YES    |
| list             | 200, blob returned                            | 200, blob returned | YES |
| get-byte-equal   | 206, byte-equal                               | 206, byte-equal | YES    |
| blob-delete      | 409 ContainerLocked (WORM default-immutable)  | 202             | NO     |
| container-delete | 409 ContainerLocked (WORM default-immutable)  | 202             | NO     |

Round-trip result: smalt 4/6 PASS, 2 errors (honest: 2 real failures on the
delete legs). Azurite 6/6 after `--skipApiVersionCheck`.

## Divergences (KD candidates, typed)

1. **KD-candidate: default-WORM container create** — smalt `Put Container`
   stores `"immutable" => true` by default
   (`lib/smalt/data_plane/blob_storage.ex:157`,
   `"immutable" => Map.get(opts, "immutable", true)`), so the delete arm of
   `worm_blocked?/2` (`blob_storage.ex:2076`) refuses `Delete Blob` and
   `Delete Container` with 409 `ContainerLocked`
   ("container policy enforces immutable WORM retention", blocker
   `:legacy_immutable`) for the default 1095-day retention on ANY freshly
   created container with no policy. Azurite (and real Azure without an
   explicit policy) answers 202. This is documented as intentional
   (`blob_service.ex:204-208`), but it makes the plain create→delete SDK
   lifecycle impossible over HTTP — a lifecycle-parity divergence, typed
   `:legacy_immutable` default-on at the HTTP face.
2. **Azurite-only (not a smalt defect)**: Azurite 3.37.0 rejects
   `x-ms-version: 2026-10-06` (SDK 12.34 default) with 400 on every op;
   smalt accepts it. Workaround: `--skipApiVersionCheck`. Typed as an
   Azurite currency gap, not a smalt divergence.

## Standing

**SPIKE-PARTIAL_ALIVE** — not SPIKE-ALIVE by the task's own gate (standing is
SPIKE-ALIVE iff both backends pass the full round trip). Both backends agree
on the write/read/list half (4/6 ops, identical status codes, byte-equal GET);
the delete legs diverge on KD candidate #1. Errors reported, not suppressed.
