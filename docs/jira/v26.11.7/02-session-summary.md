# 02-session-summary

Standing: PARTIAL

Factual summary of the v26.11.7 azure-out migration session. Counts were
re-read from cited files at write time (2026-11-05). No git actions.

## 1. Subject and wave structure

Subject: migrating the Azure dialect layer (dialect #1 Azure/ARM with
armkv + kv7 sub-dialects, and dialect #0 STS wire face) out of the smalt
BEAM core, per the draft charter
`docs/jira/v26.11.7/00-azure-out-migration-charter.md` (Standing:
DRAFT-DECISION-PENDING — nothing in it authorizes landing until the
operator admits it).

Wave structure:

1. **Explore wave (~20 lanes)** — read-only census of the dialect surface
   across smalt and arcus; produced the 122-file / 35,455-line inventory
   and the C1–C7 anchor tables.
2. **Write wave (~40 lanes)** — arcus-side port (ontology face, wire-law
   clusters, error emitters, KD register, test mass) recorded in
   `arcus docs/jira/v26.11.6/migration-ledger.md`; smalt-side docs and
   receipt lanes.
3. **P3 re-anchor + convergence** — 8 receipt lanes re-anchoring the
   C1–C7 loci per `01-c1-c7-re-anchoring-plan.md`, plus register and
   stance-note re-anchoring.

## 2. Arcus landing

The arcus side is recorded in
`/Users/sac/arcus/docs/jira/v26.11.6/migration-ledger.md`
(Standing: PARTIAL_ALIVE) and the ported register
`/Users/sac/arcus/docs/jira/v26.11.6/KNOWN_DIVERGENCES.azure.md`
(191 KD-nn rows + KD-A1..A4 = 195 rows, re-counted on disk).

- Tier 1: public-cloud-core ontology face moved to arcus; Azure/ARM
  reclassified as `AZURE-#1(ARCUS)` in `internal/dialect/azure`.
- Tier 2: wire-law clusters ported as byte-laws: SASL ANONYMOUS only,
  descriptor 0x44, attach <=14 tripwires, .NET-GUID lock-token
  reordering, EH partitions `["0","1"]`, cosmos headers, ARM `//`
  collapse, RFC-1123 dates.
- Tier 3: error ABI via three emitters (`errors_blob.go`,
  `errors_armwire.go`, `errors_aad.go`).
- Tier 5: ~102-file test corpus ported into `internal/dialect/azure/`.
- Wire courts on disk:
  `internal/dialect/azure/wire_court_test.go`,
  `routing_court_test.go`, `error_code_parity_court_test.go` (three
  named in the P3-L8 receipt; the "4 wire courts" contract count
  includes a frame_codec-class court in the ported test mass).

## 3. Smalt-side changes this session

- Draft charter: `docs/jira/v26.11.7/00-azure-out-migration-charter.md`
  (174 lines; DRAFT-DECISION-PENDING).
- Re-anchor plan: `docs/jira/v26.11.7/01-c1-c7-re-anchoring-plan.md`
  (270 lines; C1_ARM_REST 19 loci through C7_EVENT_PLANES 8 loci).
- 8 P3 receipt lanes under `docs/jira/v26.11.7/receipts/` — six files
  on disk: `p3-l1-c1-reanchor.md` (PARTIAL; per-anchor sha256 pins),
  `p3-l2-c2-reanchor.md`, `p3-l3-c3-reanchor.md`,
  `p3-l7-c7-reanchor.md`, `p3-l8-register-reanchor.md` (PASS),
  `p3-l9-stance-notes.md` (PASS); L4–L6 receipts not present at
  write time.
- KD-212 row appended to `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`
  (lane M1, pre-existing before P3-L8's append-only note block).
- 5 wire-court parity markers: P3-L8 re-pointed the dialect-conformance
  court note in `lib/smalt/plane/control_supervisor.ex` `@moduledoc`
  (comment-only diff) at the arcus counterparts.
- WIRE_PARITY evidence notes: ~24 rows across the P3 receipts
  (per-anchor verdict tables, e.g. the 19-row C1 table in
  `p3-l1-c1-reanchor.md`).
- `delivery_encoder.ex` docstring fix: C5 anchor mapping corrected
  (`delivery_encoder.ex:124`, `:131-133` → `sb_rest.go`).
- Emulation-stance notes: two evidence-note bullets appended to
  `docs/explanation/emulation-stance.md` (arcus co-pin; kv7
  core-residency) — append-only, `64a65,74`, prose untouched
  (P3-L9 receipt).

## 4. Registered divergences / deltas

Arcus-side (in `KNOWN_DIVERGENCES.azure.md`, all OPEN):

- **KD-A1** — arcus `tenancy_dns.go` admits CAA on PUT; smalt
  `lib/smalt/arm/dns.ex:121` refuses — lawful arcus delta by charter
  closed-set, but the dialect pair diverges.
- **KD-A2** — gen-2 chain link digest: arcus sha256 (Go-stdlib-only
  zero-dependency law) vs smalt/posh BLAKE3; framing byte-compatible,
  digest H differs.
- **KD-A3** — Web PubSub / negotiate / oidc-authorize / kv7-wire courts
  SKIP-LOUD without a live substrate; no PASS witness in-tree.
- **KD-A4** — arcus Mock drops the BLAKE3 turnstile header
  (registered simplification in `internal/mock/mock.go`).

Smalt-side premise correction:

- The C6 re-anchor premise that a smalt `oidc_sts.ex` was the subject
  was corrected at plan time: the smalt subject is
  `lib/smalt/arm_gateway/router.ex` (STS/OIDC legs) +
  `lib/smalt/auth/bearer.ex`; the arcus counterparts are `oidc_sts.go`
  (465 lines), `oidc_discovery.go`, `oidc_sts_test.go`,
  `errors_aad.go` (`01-c1-c7-re-anchoring-plan.md` § C6).
  Charter line 134's `oidc_sts.ex` sha256 pin predates this correction.

## 5. Open items

- **P1 membrane decision** — arcus vs posh as the dialect membrane;
  DRAFT-DECISION-PENDING, operator decides (charter §2). KD-212 flips
  stay with smalt kd-registrar until P1 admits.
- **NOTICE/LICENSE** — arcus NOTICE.md final landing is a separate
  receipted step; draft at `/Users/sac/arcus/docs/jira/v26.11.6/NOTICE-draft.md`.
  NOTICE files are hand-edited legal instruments, never generated
  (charter constraint 1).
- **P4 strip evaluation** — UNSUPPORTED by default until P1–P3 land
  (charter §3).
- **KD-151 / KD-5 evidence** — open rows in the ported register (KD-05
  verbatim-open per ledger Tier 4); live-substrate evidence owed.
- **9443 cutover** — cordon BEAM arm_port 9443 before any new membrane
  binds it; order normative (charter constraint 4).
