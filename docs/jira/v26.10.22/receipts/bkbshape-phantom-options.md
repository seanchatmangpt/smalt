# BK-BSHAPE — phantom SDK-option census across bench/probe harnesses

**Standing:** **ALIVE** (fix verified on the wire at step level; one rerun
BLOCKED-with-owner). Context: solo

Class question (from PB1SDKFIX/KD-IM): do other harnesses pass options that
do not exist in the installed SDKs, silently dropping behavior they claim to
measure?

## Method (mechanical)

- Corpus: every harness in `scripts/`, `scripts/bench/`, `verification/ts/`
  importing an installed `@azure/*` SDK — 28 files
  (`/tmp`-scratch list: scripts/bench/{a2_cas_contention,b2_blob_ts,b2b_blob_hdr,b3_cosmos_ts,b3b_cosmos_hdr,b4_messaging_ts,c1_cosmos_blob_pipeline,c2_sb_cosmos,c3_eh_blob_archive,c4_kv_cosmos_crypto,c7_cross_soak,c8_chaos_cross,ctq2_txn,lifecycle_harness,pb1_cosmos_sdk,pb6_wire_leg,scvd_t18_eh_ramp,scvd_tier12,t36_boot_court}.mjs +
  verification/ts/{appconfig,kd114,kd114-sharedkey,kd73-74,kd85,census,sb-emulator,newcaps,sb-extra}.probe*.cjs/mjs).
- Extracted every `key:` token in those files (450 unique), deduped, and
  checked each against the installed typings corpus (10.3 MB of `.d.ts` from
  `verification/ts/node_modules/@azure/{cosmos@4.10.1,storage-blob@12.34.0,service-bus@7.10.0,event-hubs@6.0.4,keyvault-keys@4.10.2,app-configuration@1.13.0,identity,arm-resources}`,
  word-exact match). 147 keys absent from all typings — every one is a local
  harness field (lane/surface/p50/verdict/…), none an SDK option at a call
  site (cross-checked by intersecting phantom keys with SDK-call lines: only
  document-body fields like `pk:`/`seq:` appear there).
- `@azure/keyvault-secrets` and `@azure/data-tables` are NOT installed —
  no census possible, no harness imports them.
- Python: `.venv` does not exist; `.venv-cli` exists but has no azure
  packages. `scripts/bench/b5_python_mirror.py` imports azure.cosmos/azure.storage.blob
  but passes zero option kwargs (no `match_condition`/`if_match`/etag usage);
  `smalt-cli` verify.py likewise. No phantom exposure; venv install not
  required for this pass (loud skip, not silent).

## Findings — 3 phantom sites, all the same class (cosmos `ifMatch`)

`ifMatch` is not an option on @azure/cosmos 4.10.1 `RequestOptions` (only
`accessCondition: { type: "IfMatch", condition: etag }` exists; the `ifMatch`
strings in the typings corpus belong to storage-blob/service-bus
`RequestConditions` and the TransactionalBatch API — different interfaces).
Phantom sites (header never reached the wire; the conditional replace was
unconditional):

| File:line | Option used | Classification | Disposition |
|---|---|---|---|
| `scripts/bench/pb6_wire_leg.mjs:74` | `{ ifMatch: leaseEtag }` on `item.replace` (step 3-cas) | measurement-invalidating (PB-6 claims If-Match CAS settlement walk) | FIXED + rerun, see below |
| `scripts/bench/pb6_wire_leg.mjs:78` | `{ ifMatch: cas.resource._etag }` (step 4-seal) | measurement-invalidating | FIXED + rerun |
| `scripts/bench/ctq2_txn.mjs:210` | `{ ifMatch: etag }` (step 1-cosmos-cas-put) | measurement-invalidating (CTQ2 txn gate claims CAS put) | FIXED; full-gate rerun BLOCKED-with-owner; fix verified at step level on lane substrate |

Non-findings worth pinning: `maxItemCount`, `disableAutomaticIdGeneration`,
`retryOptions`, `maxRetryAttemptCount`, `connectionPolicy`,
`enableEndpointsDiscovery`, `abortSignal`, `timeoutInMs`, `maxRetries`,
`maxWaitTimeInMs`, `maxAutoLockRenewalDurationInMs` all exist in the installed
typings and are used at real call sites — no other phantoms.

## Fixes + rerun evidence

### pb6_wire_leg.mjs — fixed and rerun ALIVE

Both sites swapped to `accessCondition: { type: "IfMatch", condition: etag }`.
Rerun (2026-10-22, private lane-b6 substrate via `bench_boot b6`, ports
39060..39065, anonymous, TLS twin 39064, @azure/cosmos 4.10.1, WARM=5 ITERS=20):

```text
[pb6-wire] db/container ready pb6w-1792669945461 endpoint=https://localhost:39064 sdk=4.10.1
[pb6-wire] warmup 5
[pb6-wire] measured 20
[pb6-wire] wrote .../tmp/bench/pb6-wire-steps-bshape.json errors=0
```

Step p50s: 1-lease 0.79 / 2-validate 0.63 / 3-cas 0.75 / 4-seal 0.73 /
5-observe 0.65 ms, errors=0 — the corrected-shape CAS walk runs clean.
Output: `tmp/bench/pb6-wire-steps-bshape.json`.

### ctq2_txn.mjs — fixed; full-gate rerun BLOCKED-with-owner

Fix applied (line 210). Step-level verification: on the lane-b6 anonymous
substrate the txn gate ran with the fixed shape and `1-cosmos-cas-put`
p50 = 2.3 ms real on the wire with steps 1-3 succeeding
(`tmp/bench/ctq2-bshape.jsonl`; VERDICT FAIL only because the SB leg cannot
ride an anonymous SASL-ANONYMOUS-only lane substrate — expected posture).
The full gate needs the main enforce-mode substrate, which at census time
refuses TLS on 9443/9444 (curl exit 35 on the STS endpoint; witnessed from
this lane twice, `ECONNRESET` from the cosmos SDK path) — the shared
substrate is degraded/congested, not this lane's tree. BLOCKED-with-owner:
substrate ops (BK-AMQPF/BK-CERTA owners) to rerun
`CTQ2_N=50 node scripts/bench/ctq2_txn.mjs` against a healthy 9443/9444;
expect the gate to pass with `1-cosmos-cas-put` timings unchanged (the CAS
header now actually gates the put — a real 412 path now exists that did not
before, so contention behavior in CTQ2's single-writer workload should be
unaffected).

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
# typings census (cosmos ifMatch check):
grep -c ifMatch verification/ts/node_modules/@azure/cosmos/dist/esm/request/RequestOptions.d.ts   # 0 hits in RequestOptions
bash -c 'source scripts/bench/lib.sh; bench_boot b6 || exit 2
export NODE_EXTRA_CA_CERTS=$PWD/tmp/dev-certs/dev-cert-39064.pem
export PB6_TLS=https://localhost:39064 PB6_WIRE_WARM=5 PB6_WIRE_ITERS=20 PB6_WIRE_OUT=$PWD/tmp/bench/pb6-wire-steps-bshape.json
node scripts/bench/pb6_wire_leg.mjs'   # errors=0
```
