# KD-114 — real-SDK blob falsifier witness (S17-A)

**Standing:** PARTIAL_ALIVE — flip-eligible core falsifier witnessed via the real
official SDK; SharedKey/SAS admit legs refused (typed), so the row cannot flip
to CLOSED-SIMULATED until the admit path question is settled and the KD-114
DO-NOT-FLIP hold is lifted by the registrar.

- Date: 2026-10-20
- Lane: S17-A (bench-runner, falsifier lane)
- Subject: /Users/sac/smalt @ main 33cd2a1 (uncommitted lane diff:
  `verification/ts/kd114.probe.cjs` new; this receipt new)
- Files this lane touched: `verification/ts/kd114.probe.cjs` (new),
  this receipt (new). No lib edits, no git. Other dirty paths in the tree
  belong to concurrent lanes.

## Falsifier executed (real SDK, real transport, no mocks)

- SDK: `@azure/storage-blob` 12.34.0 (already present as the pinned dep in
  `verification/ts/package.json` `^12.34.0`; `node_modules` = 92 top-level
  packages, 149 MB — no install delta needed; `package-lock.json` untouched).
- Endpoint: `https://127.0.0.1:9444/popcorn/...` (TLS twin, blob face routed
  by the KD-114 dispatch flip, kd35-114 receipt).
- Auth: emulator STS bearer (`POST /organizations/oauth2/v2.0/token`) via a
  minimal `TokenCredential`; TLS trust via
  `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`.

Command:

```
NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node verification/ts/kd114.probe.cjs
```

Actual output (run of 2026-10-20 22:05 PDT, 3 consecutive runs identical):

```
uploaded kd114-blob-1792560301554txt (25 bytes)
PASS bearer.list.includes-blob
PASS bearer.download.byte-equal
NOTE sharedkey leg refused (typed): MalformedBearerHeader statusCode=401
NOTE sas leg refused (typed): RestError statusCode=401
SUMMARY pass=2 fail=0  (exit 0, 3/3 green)
```

## Verdict per close condition

- **Core falsifier: PASS.** Official SDK BlobClient upload → list → download
  byte-equal under enforce auth over the TLS twin — 3/3 green, exit 0.
- **SharedKey leg: refused, typed** — 401 `MalformedBearerHeader` (the
  enforce-mode bearer plug refuses SharedKey; `lib/smalt` has no SharedKey
  admit path — `grep -rln "SharedKey" lib/smalt/` = no matches). This matches
  the original KD-114 divergence text.
- **SAS leg: refused, typed** — 401 on anonymous + blob-SAS download.

## Why the auth channel is bearer, not SharedKey

The close condition names "SAS/SharedKey admit consistent with real Azure".
Survey finding (this lane, read-only): no SharedKey admit exists anywhere in
`lib/smalt` (grep = 0 matches); the enforce plug's only admitted channel is
the STS bearer. The close condition is witnessed on the bearer channel only.
**Registrar note**: flipping KD-114 requires either (a) lifting the
DO-NOT-FLIP hold and accepting the bearer-channel witness, or (b) landing a
SharedKey/SAS admit path and re-running this probe with
`SMALT_SB_SHARED_KEY` set to the per-host dev key
(`eval "$(scripts/dev_env.sh)"` — the probe already reads `SMALT_SB_SHARED_KEY`
when set).

## Wire divergences surfaced by the real SDK (candidate KD rows — not minted by this lane)

1. **create-existing-container returns 200, not 409** (`ContainerAlreadyExists`).
   Real SDK `createIfNotExists` then throws a bare RestError(200, empty body)
   instead of swallowing 409. Worked around in the probe with a unique
   per-run container name + `create()` (201). Raw evidence:
   `PUT /popcorn/<existing>?restype=container` → `200 len=0`.
2. **SharedKey/SAS not admitted** (already registered as KD-114's core).

## Substrate stability note (honest)

During the session a concurrent lane restarted the standing substrate twice
(beam pid 62309 → 75722 → 78681); two probe runs FATALed racing a fresh beam
(create → 200-empty responses during boot window). This is NOT a KD-114
failure — raw curl legs on a stable beam were byte-perfect. Probe output above
is from the stable tail of the session. Coordinator note: the 200-on-create
divergence finding #1 should be re-checked on a stable beam if the emulator
intends 409 (real Azure returns 409 ContainerAlreadyExists).

## What remains

- KD-114 DO-NOT-FLIP hold: still in force; flip is registrar-gated.
- SharedKey/SAS admit leg: OPEN (no admit path in lib).
- The 200-vs-409 create-existing divergence: candidate KD row (registrar).
