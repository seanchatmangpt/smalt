# Cross-industry pillar matrix — 5 pillars × 6 industries (v26.10.22)

Every cell is read from the packs' `gates/*.rq` + `witnesses/{pass,fail}/*`
files on disk (`/Users/sac/ggen-marketplace/packs/industry-*`) and the
witness-court runners; landed vs in-flight is read from `git status` in
`/Users/sac/ggen-marketplace` (branch main, working tree, 2026-10-22). Lane
reports were NOT trusted for cell status — statuses are as-of-disk.

The five-pillar spec (canonical statement:
`packs/industry-semantic-cad-bim/PILLARS.md`, IND-6):

- **P1** — sovereignty / isolation: a matter-, ledger-, batch-, project-, or
  classification-scoped isolated store with a per-subject journal path.
- **P2** — BYOK/SKR attestation, the AZ-2 SKR shape: release-time token
  `measurement_digest` == expected attestation fingerprint;
  smalt `lib/smalt/attestation/maa.ex` `secure_key_release/3`
  (AZ-2, KD-168, shim court `scripts/shim_court/az2_maa_court.sh`).
- **P3** — no-model-training / proposer-judge: every AI-derived mutation or
  annotation must carry `prov:wasGeneratedBy` a `*:JudgeActivity` before it
  commits. Substrate law: BK-111 PROV-O Agent chain,
  `docs/jira/v26.10.22/receipts/bk111-provo-agent-chain.md`
  (Entity/Activity/Agent chain + fail-closed `verify_ntriples/1`).
  The dispatch's "129r" citation is UNRESOLVED: no BK-129r receipt or
  register row exists on disk in either repo (grep 2026-10-22); BK-111 is the
  landed law cited instead. Re-cite if BK-129r lands.
- **P4** — Entra/ACP identity walls: per-pack coverage is partial and
  declared, never silent.
- **P5** — Merkle self-authentication: sealed root + 320-byte (640-hex-char)
  receipt digest.

## Status legend

- **landed** = committed on ggen-marketplace main (commit cited).
- **in-flight** = gates + witnesses on disk in the pack working tree,
  uncommitted (`git status`) at reading time.
- **N-A** = pack declares the pillar out of scope (reason cited).

## Matrix

| Industry | Pack | Lane | P1 isolation | P2 BYOK/SKR | P3 proposer-judge | P4 identity walls | P5 Merkle seal |
|---|---|---|---|---|---|---|---|
| Legal / e-discovery | `packs/industry-legal-ediscovery` | IND-1 | **landed** — `gates/040_matter_isolation.rq` (MatterStore, `journalPath` anchors `^/data/smalt/journal/matter_`) | **landed** — `gates/050_skr_attestation.rq` (AZ-2 SKR shape) | **landed** — `gates/060_proposer_judge.rq` (`lex:JudgeActivity`) | **landed (wall analog)** — pre-existing `gates/030_ethical_wall.rq`, mapped to P4 by consumer `examples/industry/legal-ediscovery/PILLARS.md`; a domain wall, not a true Entra/ACP wall | **divergent** — `gates/070_retention_policy.rq` is a retention law labeled P5 by IND-1, NOT a Merkle seal; Merkle rides the `lex:kvSealThumbprint` custody chain, cited not gated (pack `RECEIPT.md` §6 limitations) |
| Financial | `packs/industry-financial-ledger` | IND-2 | **landed** `0fc747a62` — `gates/040_ledger_isolation.rq` + pass/fail witnesses | **landed** `0fc747a62` — `gates/050_skr_attestation.rq` (AZ-2 shape) | **landed** `0fc747a62` — `gates/060_proposer_judge.rq` (`fin:JudgeActivity`) | **OPEN** — no gate, no typed out-of-scope declaration on disk (README pillar table has no P4 row; the cited `examples/industry/financial-ledger/PILLARS.md` does not exist, find 2026-10-22) | **landed** `0fc747a62` — `gates/070_merkle_seal_missing.rq` |
| Pharma 21 CFR | `packs/industry-pharma-21cfr` | IND-3 | **landed** — `gates/050_journal_scope_missing.rq` (per-batch journal path) | **landed** — `gates/060_esig_attestation_missing.rq` (AZ-2 `sha256:` fingerprint) | **landed** — `gates/070_ai_annotation_unadjudicated.rq` (`p11:JudgeActivity` + verdict) | **landed (analog)** — `gates/010_signature_missing.rq`: PROV-O-attributed e-signature (21 CFR 11.50/11.70) carried as the P4 analog ("P4 carried by existing signature gates", pack `RECEIPT.md`) | **landed** — `gates/080_merkle_seal_missing.rq` (sealed root + receipt digest) |
| Aero/defense | `packs/industry-aero-defense` | IND-4 | **landed** `0fc747a62` — `gates/040_storage_segregation.rq` (classification isolation) | **landed** `0fc747a62` — `gates/050_execution_attestation.rq` (AZ-2 measurement fingerprint) | **in-flight (BK-143r)** — `gates/070_proposer_judge.rq` + pass/fail witnesses exist on disk but are UNTRACKED/uncommitted, no BK-143r receipt in either repo (grep 2026-10-22); the old N-A declaration cited `examples/industry/aero-defense/PILLARS.md`, which does not exist on disk | **OPEN** — no gate, no typed declaration on disk | **landed** `0fc747a62` — `gates/060_merkle_seal_missing.rq` (sha256 `ad:sealedRoot`) |
| Manufacturing DfLSS | `packs/industry-manufacturing-dflss` | IND-5 | N-A (no pillar gates in pack) | N-A | N-A | N-A | N-A |
| Semantic CAD/BIM | `packs/industry-semantic-cad-bim` | IND-6 | **landed** `6713e34f7` — `gates/040_design_isolation.rq` (`cad:ProjectStore` journalPath `^/data/smalt/journal/project_`) | **landed** `6713e34f7` — `gates/050_attestation.rq` (`cad:attestationFingerprint`, AZ-2 shape) | **landed** `6713e34f7` — `gates/060_proposer_judge.rq` (`cad:JudgeActivity` before `cad:mutatesElement`) | **NOT-COVERED (declared)** — `packs/industry-semantic-cad-bim/PILLARS.md`: "identity-wall gates live in the Entra/ACP surface lane, not the pack" | **landed** `6713e34f7` — `gates/070_seal.rq` (`cad:receiptDigest` pattern `^[0-9a-f]{640}$`) |

## Witness counts (from disk)

Each pillar cell carries pass+fail witnesses under `witnesses/{pass,fail}/`
(except dflss, which carries only its 3 domain laws):

| Pack | Gates on disk | Witness legs (pass+fail) | Pillar gates |
|---|---|---|---|
| industry-legal-ediscovery | 7 | 14 | 040/050/060/070 |
| industry-financial-ledger | 7 | 14 | 040/050/060/070 |
| industry-pharma-21cfr | 8 | 16 | 050/060/070/080 |
| industry-aero-defense | 6 | 12 | 040/050/060 |
| industry-manufacturing-dflss | 3 | 6 | none |
| industry-semantic-cad-bim | 7 | 14 | 040/050/060/070 |

## Court machinery (IND-5 exemplar)

The court contract is the dflss-exemplar runner
`packs/industry-manufacturing-dflss/runners/semantic_runner.py`
(`--gate/--witness/--expectation`; exit 0 observed / 2 expectation violation /
3 structural; `REFUSED_*` typed vocabulary incl.
`REFUSED_MORE_THAN_ONE_GATE_FIRED` for exactly-one-law), wired per pack via
`gate-court.toml` → `qualification/verify.py` →
`runners/semantic_runner.py`, schema `ggen.semantic-gate-witness-court/1`.
Legal/pharma/financial/aero/cad-bim each carry a ported copy of the runner;
pharma documents its divergence (no SHACL leg — no `ontology/shapes.ttl`;
pass contract is zero gate rows).

## KD receipt lineage (canonical register:
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, rows 345-348)

| KD | Surface | Standing | Pillar relevance |
|---|---|---|---|
| KD-165 | workspace sync engine client P12 cumulative receipt verify | CLOSED-WITH-EVIDENCE (BK-106; `receipts/bk106-sync-engine-fixes.md`) | the P12 receipt chain the pillar evidence rides on |
| KD-166 | Web PubSub subprotocol echo (`lib/smalt/webpubsub/router.ex`) | OPEN (AZ-5; `receipts/az5-webpubsub.md`) | console-facing wire face for pillar-evidence viewers |
| KD-167 | MHSM release-policy assertion evaluation (`lib/smalt/data_plane/mhsm.ex`) | CLOSED-WITH-EVIDENCE (AZ-4; `receipts/az4-mhsm-policies.md`; collision note in `receipts/az4b-mhsm-receipt.md` — two rows under id KD-167 in the register) | P2 enforcement half: policy-checked key release |
| KD-168 | MAA measurement cross-binding (`lib/smalt/attestation/maa.ex`) | OPEN, hardware-typed-UNSUPPORTED (AZ-2; `receipts/az2-maa-attestation.md`) | P2 the AZ-2 SKR shape itself; quote-signature leg UNSUPPORTED (no TEE silicon) |

Register pointer drift disclosed: `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`
(57 lines) mints KD-166 as "Confidential Ledger" while the canonical register
mints KD-166 as Web PubSub — an id collision alongside the KD-167 double row;
the register head says mint-from is KD-169. Flag for the kd-registrar; not
repaired in this lane.

## Pack receipts

- IND-1 legal: `packs/industry-legal-ediscovery/RECEIPT.md` §6
  (commit `ee7e8c689`); also discloses PILLAR-SPEC-ABSENT (the BK-134 spec
  file `docs/jira/v26.10.22/pillar-audit-legal.md` never landed).
- IND-3 pharma: `packs/industry-pharma-21cfr/RECEIPT.md` (commit `9a7d227bf`).
- IND-2 financial: landed `0fc747a62` (14/14 cells; README pillar table is
  the in-repo mapping receipt — no consumer PILLARS.md exists on disk).
- IND-4 aero: landed `0fc747a62` for 040/050/060 (12/12 cells, README pillar
  table); the P3 `070_proposer_judge` gate + witnesses are on disk
  UNCOMMITTED (BK-143r in flight; no receipt yet).
- IND-6 cad-bim: landed `6713e34f7` — `packs/industry-semantic-cad-bim/PILLARS.md`
  (14/14 legs, consumer sync sha256 `992ec6d1…`).

## Standing

**PARTIAL_ALIVE** — 5/6 industries pillar-gated (committed), verified from
disk, not lane reports. Single open cell: **aero P3 proposer-judge**
(gate + witnesses on disk but uncommitted; no BK-143r receipt in either repo
as of 2026-10-22). When BK-143r commits and receipts, flip the aero P3 cell
and this line — after re-deriving from `git status -- packs/industry-aero-defense`,
never from the lane report.
- IND-5 dflss: exemplar runner only — no pillar-gate receipt, no PILLARS.md.

## Falsifier

Any cell above flips if its gate/witness files change on disk or the pack
working tree is committed/checked out differently; re-derive from
`git -C /Users/sac/ggen-marketplace status --short -- packs` plus the
`gates/`+`witnesses/` listings before citing this matrix downstream.
