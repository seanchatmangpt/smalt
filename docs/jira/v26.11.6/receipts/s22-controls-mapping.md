# S22 Controls Mapping — Statutory Citations to LANDED Controls (v26.11.6)

Standing: PARTIAL_ALIVE

Context: solo (S22-D1 doc-only lane, canonical smalt checkout, no commits)

Lane: S22-D1 (doc-only, v26.11.6). Repo: /Users/sac/smalt (canonical
checkout, no commits). This doc maps statutory citations to controls that
ALREADY LANDED with receipts — it lands zero code and admits zero new
capability.

## Scope-check context (S7 verdict)

S7 scope check CLOSED 2026-11-05: statutory docket surface = vocabulary
lane, doc-first, option (ii) NO-BUILD (public-cloud-ontology precedent).
Each citation below maps to an existing LANDED control; the remainder of
S22 (schema/shape-drift injection court) is REGISTERED, NOT BUILT — it
admits nothing until its receipt lands.

## Mapping table

| Statutory citation | Landed control | Receipt pin | Standing |
|---|---|---|---|
| ASC 450 (loss-contingency disclosure / audit-trail preservation) | Typed refusal + `violating_frames` bisect + windowed replay ledger on protocol drift | `docs/jira/v26.11.6/receipts/lane9-aoq-admission.md` | ALIVE |
| SOX 404 (internal control over financial reporting — tamper-evident audit trail) | gen-2 BLAKE3 chain-link law + mutation-killing gate fixtures (gen-erase, wrong-gen, seq-not-in-digest, ledger-id-unbind) | `docs/jira/v26.11.6/receipts/lane11-blake3-chain-retarget.md` | ALIVE |
| EU AI Act (Art. 12 log/record-keeping obligations, as cited surface) | Same two controls: typed-refusal admission ledger (lane 9) + tamper-evident chain (L11) | both receipts above | ALIVE |
| FRE 902 (self-authenticating evidence — hash-verified records) | gen-2 BLAKE3 chain + cross-language byte-identity vectors (`verification/chain_link_vectors.json`, Elixir == Go == Python) | `docs/jira/v26.11.6/receipts/lane11-blake3-chain-retarget.md` | ALIVE |

Notes per row:

- **ASC 450 / EU AI Act rows share the lane 9 control**: `Smalt.Aoq.Admission.admit_batch/2`
  produces typed refusals (`:smalt_shacl_violation`), bisects to
  `violating_frames` (worst case log2(N) per violator), and rides the
  windowed replay ledger. Standing cited from the receipt, re-read at
  authoring time: ALIVE.
- **SOX 404 / FRE 902 rows share the L11 control**: gen-2 link digest is
  `BLAKE3("SMALT/AOQ-LINK/v2" ‖ raw32(prev_root) ‖ seq::u64-BE ‖ raw32(data_hash) ‖ sub_ledger_id)`,
  `chain_gen => 2` rides the signed payload, gen-1 (sha256 hex-fold)
  verifies forever, unknown gen refuses typed. Gate: 14/14 mutation
  fixtures refused + non-vacuous shim court.

## Scan-surface fact (namespace court)

`scripts/verify_public_cloud_ontology.py` scans URIRefs only — literals
are exempt (`isinstance(term, URIRef)` at verify_public_cloud_ontology.py:62).
Statute IRIs (e.g. a hypothetical `https://law.gov/sox404`) would FAIL the
zero-proprietary/unratified-namespace court. Therefore statutory citations
live in literal prose only — never as graph IRIs. This is the mechanism
behind the no-build verdict: a vocabulary lane whose citations ride in
literals keeps the court green with zero ontology edits.

## Honest-claim boundary

**Claimable** (this doc plus its pins):

1. The mapping exists and every receipt pin it names resolves on disk.
2. A court-admitted control-objective vocabulary may exist — as a
   registered possibility, not a built one.

**NOT claimable** — none of the following is asserted by this doc, the
S22/S7 rows, or the graph:

- "SOX-compliant", "ASC 450-compliant", "AI-Act-conformant",
  "FRE 902 docket-admissible", or any compliance certification.
- Any legal-effectiveness claim of any kind.
- That the un-landed schema/shape-drift injection court exists — it is
  registered, not built, and admits nothing until its receipt lands.

The graph cites statutes; it does not implement them.

## Gates (run at authoring, this session)

- `just docs-dod-check` — the pinned-path existence rows all OK; the
  aggregate recipe currently exits 1 on a PRE-EXISTING foreign-lane MISS:
  KD-195 in `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` cites
  `docs/jira/v26.11.5/receipts/l14-kafka-adapter.md`, an arcus-repo path
  (exists at `/Users/sac/arcus/docs/jira/v26.11.5/receipts/l14-kafka-adapter.md`)
  that `scripts/kd_receipt_fence.py` resolves against the smalt root. Not
  this lane's surface; disclosed, not silently passed. lane-owned portion
  green (no MISS row touches S7/S22 or the mapping doc).
- `python3 scripts/receipt_index.py` → exit code 0, clean regeneration
  (s22-controls-mapping indexed).
- `python3 scripts/verify_public_cloud_ontology.py` → exit code 0, VERDICT:
  ALIVE [GREEN] — proves this doc-only step touched no ontology (court
  green over the unchanged graph).

## See Also

`docs/jira/v26.11.5/strata-backlog.md` (S7/S22 rows, refreshed this lane)
