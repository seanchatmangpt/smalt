# Release Announcement Draft — smalt v26.10.16

DRAFT ONLY — not sent, not minted into any publish surface. Standing lines are
pre-two-green; the wrap is closing. Tag reference: **v26.10.16** (terminal
window; tag prep in [TAG-PREP.md](TAG-PREP.md), no tag executed). Final court
verdict stays a placeholder until a court-x2 run logs
`[COURT-X2] RECEIPT: gate PASSED` (latest completed: run-30, RED — see Court
trajectory).

## Headline (from FINAL.md)

> **smalt v26.10.16 — BEAM-native local cloud-edge emulator: ARM-style control
> plane on 9443, TLS twin 9444, data plane 8443, AMQP Service Bus 5672, Event
> Hubs 5673, MCP tool surface 9545. Point SDKs/CLIs at loopback, no cloud needed.
> Standing: PARTIAL_ALIVE (pre-two-green; landing HEAD `7275032`, lineage
> f0d2f47..7275032, 12 commits).**

## Capabilities (honest standing per capability)

- **Projection architecture — REAL, not planned (W1 landed; W2 landed,
  working tree).** The ggen projection architecture from
  [PROJECTION-ARCH-PLAN.md](PROJECTION-ARCH-PLAN.md) moved from plan to
  admitted code:
  - **W1 ConfigKey + StoreTable — LANDED (commit `8361816`).**
    `lib/smalt/config.ex` — 46-key generated accessor (exact per-call-site
    override semantics, 3 exemplar migrations); `lib/smalt/store_tables.ex` —
    projected registry, 33 owned + 19 shadow typed rows, consumed by
    `store.ex`/`state.ex`/`dets_mirror.ex`; the hand lists are dead and the
    swept-but-unowned bug class is closed. Replay fences: config + store
    identity tests, 10/0.
  - **W2 CascadeEdge — LANDED (working tree).**
    `lib/smalt/cascade_edges.ex` — 281 LOC generated from the
    smalt-substrate-pack ontology, 23 CascadeEdge rows, GENERATED/DO-NOT-EDIT
    header; capture-then-sweep edges declared and dispatched, owner drop
    functions stay hand-written (residue doctrine). Fenced by
    `test/cascade_replay_identity_test.exs` +
    `verify/cascade-coverage.unbound.rq` (run in-test).
  - **W2 semconv — LANDED (working tree).**
    `lib/smalt/telemetry/semconv/registry.ex` — 252 LOC projected from
    `model/smalt.yaml` via the new **smalt-semconv-pack**; closed-names +
    closed-attrs laws; drift fence `test/semconv_test.exs` (model fence +
    grep fence).
  - **W2 Canonical riders — LANDED (working tree).**
    `lib/smalt/projection/canonical.ex` — THIRD_PARTY (96 lines changed) and
    capabilities.json (+525) identity blocks are now Canonical.write riders,
    not hand-synced prose; fence `test/canonical_projection_test.exs`.
- **Affidavit WASM engine — ALIVE (engine-verify surface; updated 2026-10-17,
  KD-89 closed).** Mounted artifact re-pinned to upstream rebuild `a8c3c2b`;
  CTRT seal path live, classical verify adjudication live
  ([r215](receipts/r215-affidavit-seal-court.md): 113 tests / 0 failures, forge
  rejections typed), ML-DSA-65 engine-adjudicated forge court witnessed
  (KAT accepted via `pqc_verify`, tamper refused `ml_dsa65_rejected`,
  suites 25/0 + 76/0) in
  [kd89-ml-dsa-closure.md](receipts/kd89-ml-dsa-closure.md); KD-89
  CLOSED-WITH-RECEIPT. Honest residual: ledger-level attestation stays
  classical-only; `verify_signature alg=ML_DSA65 → unsupported_algorithm` is
  upstream-by-design (PQC routes through the dedicated ops). No faked pass.
- **Substrate — PASS (offline tier).** Native HCL enclave pipeline
  (`parse → plan/apply → destroy`), 41 admitted resource types (mechanically
  counted from `@admitted_resource_types` in `lib/smalt/registry.ex`),
  2435-test offline suite, AMQP/EH wire tier, blob WORM / cosmos etag-CAS /
  ledger-chain / queue-capacity / lock-clamp invariant gates (6/7 PASS —
  `appconfig-etag-cas` red typed as DEF-2 transient boot contention under
  concurrent lane builds, non-vacuity fixtures all correctly REFUSE).
- **Trust shim v2 — PASS (host-setup prerequisite, reclassified per WRAP_LEDGER
  "Enclave trust hop").** 4-leg proof in `scripts/trust_shim/`: loopback-only
  SAN gate + leaf-fingerprint pin, hardened-runtime refusal, interposed
  `SecTrustEvaluateWithError`/`SecTrustEvaluate`; use + codesigning constraints
  witnessed in `scripts/trust_shim/README.md`.
- **Console clients — PASS.** Sovereign Console (Next.js 16, air-gapped,
  zero-egress, networking only through `lib/smalt.ts`), `ws-court` **PASS=42
  FAIL=0 SKIP=1** (quiet re-run is the standing datum), smalt-cli two-venv
  pytest tier.
- **Diátaxis docs — PASS.** tutorials/how-to/reference/explanation restructure
  landed; `just docs-dod-check` exit 0 (23/23 paths OK), Diátaxis relative-link
  sweep 0 broken links, naming sweep PASS 0 violations / 46 allowed.
- **KD register — 94 rows (KD-01..KD-94).** Canonical table
  [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md).
  This window flipped KD-45/46/53/54/68/70/71/76 CLOSED-SIMULATED, minted
  KD-77/91/92/93, closed KD-89 CLOSED-WITH-RECEIPT (ML-DSA-65), and closed
  **KD-94 CLOSED-SIMULATED** — cosmos AAD Authorization shape
  (`type=aad&ver=1.0&sig=<jwt>`) up-path witnessed by a real `@azure/cosmos`
  client against enforce-mode smalt, 5/5 subtests pass
  ([r231-kd94-uppath-witness.md](receipts/r231-kd94-uppath-witness.md)); the
  fix (`Smalt.Auth.Bearer.parse_cosmos_aad/1`) landed and is fenced by the
  KD-94 describe (7 tests, 0 failures). Every divergence is pass /
  registered-divergence / loudly MISSING — no silent skips.

## Court trajectory (terminal, honest)

**31 wrap-court invocations launched, 0 two-green on this host.** Every
deterministic red identified across runs 8-30 is fixed; the residual reds are
one-per-run timing faces that flip only under CPU contention. Evidence:
[r226-court-x2-run30-red.md](receipts/r226-court-x2-run30-red.md) (run 30
`COURT_X2_RC=1`, terminal witness; run 29 no verdict — run 29.1 failed 3,
run 29.2 log truncated). The **mix suite itself is green in 5 legs**; the
residual is the sdk-smoke environmental tier + Metadata-indexer load.

**Degraded-host law landed (commit `225d8e2`): `SMALT_MAX_CASES`** caps ExUnit
concurrency (`test/test_helper.exs`) — same tests/law, less parallel pressure.
Two-green is expected under `SMALT_MAX_CASES=8 just court-x2` on a settled
host.

**Verdict: `PENDING — no two-green yet; gate is the settled-host re-court
(`SMALT_MAX_CASES=8 just court-x2`); tag cut is gated on it per TAG-PREP.md.`**

## Publish note

Publication defers to the **next window** per the wrap sequence, and stays
gated on two operator actions:

1. **ex4pm hex auth** — `cd ~/ex4pm && mix hex.publish` requires an operator
   hex account; package built + checksum on record
   ([PUBLISH_RECORD.md](PUBLISH_RECORD.md): PUBLISH-READY NO — TYPED-BLOCKED
   on B1 only).
2. **Settled-host court** — the `SMALT_MAX_CASES=8` court-x2 re-run above
   (reboot/settle first), then tag per TAG-PREP.md.
