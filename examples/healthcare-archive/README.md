# Healthcare Compliance Archive (Fortune-500 archetype)

A hospital platform team runs its nightly patient-record archival pipeline on
the smalt substrate:

1. **Blob (WORM archive)** — every night the pipeline uploads a patient-record
   export to a WORM-protected container, freezes a point-in-time snapshot of
   the export, then engages a legal hold. While the hold is active the
   substrate refuses overwrite and delete with typed `409 ContainerLocked`.
   After compliance releases the hold, a would-be tamper updates the base
   blob — but the snapshot read-back (`GET ?sharesnapshot=<ts>`) still returns
   the exact frozen bytes. A 30-day immutability policy (time-based WORM)
   rides on top.
2. **Key Vault (break-glass secrets)** — the compliance officers' break-glass
   secret is created, soft-deleted, and recoverable. On substrate builds
   where the deleted-secrets plane is not landed, the legs type out as loud
   `XFAIL` (skip-until-deleted-keys-landed, KD-102) — never a fake pass.
3. **Confidential Ledger (tamper-evident audit trail)** — every archive event
   is appended to the ledger; a duplicate append is refused with
   `409 LedgerItemAlreadyExists`; and the auditor independently RE-COMPUTES
   the Merkle chain client-side (`data_hash = sha256(canonical_json(contents))`,
   `merkle_root = sha256(prev_hash <> data_hash)` as hex-string concat,
   `prev_hash` linkage) from receipts read back over the wire — the chain is
   verified, not trusted.

## Run

```bash
cd examples/healthcare-archive
./run.sh
```

`run.sh` reuses a healthy shared substrate when present, otherwise boots a
lane-private one on v-block `v6` via `scripts/substrate-ctl` (override with
`EX3_BLOCK`) and sweeps it down after. Exit contract:
**0** pass (XFAIL counted loudly) / **1** check FAIL / **2** substrate down /
**3** loud skip.

## Endpoints (env-overridable)

| var | default | plane |
|---|---|---|
| `SMALT_EGRESS` | `http://127.0.0.1:8443` | blob data plane (bearer + `x-ms-version`) |
| `SMALT_TLS` | `https://127.0.0.1:9444` | KV + Confidential Ledger (TLS twin, CA-pinned) |
| `SMALT_ARM_HTTP` | `http://127.0.0.1:9443` | health probe |

## Transport notes (witnessed 2026-10-19)

- Blob rides the egress plane over http with bearer + `x-ms-version` — the
  vendored `@azure/storage-blob` 12.34 hard-refuses bearer-over-http, the TLS
  twin serves no blob routes (typed 404 RouteNotFound), and SharedKey is not
  admitted in enforce mode. Wire shape identical to the validated
  `verification/ts/newcaps.probe.mjs` / `verification/py` suites.
- The substrate refuses snapshot CREATION under an active legal hold
  (R5 create-arm: a hold protects existing data and blocks namespace growth),
  so the archive flow snapshots BEFORE engaging the hold — exactly what a
  real compliance pipeline does.
- KV secrets deleted-secrets routes (`/deletedsecrets`) are an in-flight
  surface: the harness types them `XFAIL` loudly rather than faking a pass.
