# RACI & Sign-Off — POSH DfLSS Organization and Approval

Parent: `dfcharter/charter-master.md` (§4 phase plan, §6 Andon protocol,
§8 team RACI, §9 sign-off). Siblings: `define.md` (tollgates T1-T5, CTQ
instruments), `measure.md`, `analyze.md`, `design.md`, `verify.md`
(receipt ladder), `andon.md` (signal protocol), `dpmo.md` (sigma math).
This document elaborates §8/§9: per-phase RACI, lane-level RACI for the
implementation fan-out, Andon RED escalation, tollgate review board,
and the controlled sign-off block. It does not contradict the master.

## 1. Master RACI (transposed from charter §8)

Roles: Sponsor = Project Sponsor; Arch = Lead Architect (Core/Rust);
Beam = BEAM Platform Engineer; Go = Go Membrane Specialist; Qual =
Quality/Compliance Lead.

| Activity | Sponsor | Arch | Beam | Go | Qual |
|---|---|---|---|---|---|
| Charter Sign-Off | A | R | C | C | C |
| Turtle Ontology (.ttl) Specs | I | A | R | C | C |
| ggen Template Development | I | A | R | R | I |
| `#![no_std]` BLAKE3 SIMD Core | I | A/R | I | I | C |
| Go Peripheral Adapters | I | C | C | A/R | I |
| Andon Gates & DfLSS Verification | I | C | C | C | A/R |
| Final Tollgate Sign-Off | A | C | I | I | R |

Legend: R = executes; A = accountable, final decision; C = consulted;
I = informed.

## 2. Per-DMADV-Phase RACI

Phase rows follow master §4; exit criteria are `define.md` §5 tollgates
T1-T5. One A per phase; the phase A owns the tollgate go/no-go call.

### 2.1 DEFINE (Weeks 1-2, tollgate T1)

| Activity | Sponsor | Arch | Beam | Go | Qual |
|---|---|---|---|---|---|
| Problem statement + scope | A | R | C | C | C |
| SPAF boundary rules | A | R | C | C | C |
| VOC/CTQ flowdown (A-K) | I | C | C | C | A/R |
| Charter + risk register | A | R | C | C | C |
| Press-release Turtle v2.0 | I | A/R | R | I | I |
| C4 context/container baseline | I | A | R | C | I |
| T1 tollgate review | A | R | C | C | R |

### 2.2 MEASURE (Weeks 3-4, tollgate T2)

| Activity | Sponsor | Arch | Beam | Go | Qual |
|---|---|---|---|---|---|
| Baseline telemetry (CTQ-B/D/K) | I | C | A/R | C | C |
| MSA: timer calibration + probes | I | C | C | C | A/R |
| Defect opportunity map (N=4) | I | I | C | C | A/R |
| Baseline DPMO record | I | I | I | I | A/R |
| Scaffold + membrane receipts | I | C | R | R | I |
| T2 tollgate review | A | R | C | C | R |

### 2.3 ANALYZE (Weeks 5-6, tollgate T3)

| Activity | Sponsor | Arch | Beam | Go | Qual |
|---|---|---|---|---|---|
| Ishikawa root-cause analysis | I | A/R | R | C | C |
| FMEA RPN assignment (master §5) | I | C | C | C | A/R |
| Category-theoretic proof | I | A/R | C | I | I |
| Face-set freeze (schema v1) | I | A | R | R | C |
| Seam lock in RESOLUTIONS.md | I | A | C | C | I |
| T3 tollgate review | A | R | C | C | R |

### 2.4 DESIGN (Weeks 7-10, tollgate T4)

| Activity | Sponsor | Arch | Beam | Go | Qual |
|---|---|---|---|---|---|
| ingress/*.ttl + egress/*.ttl | I | A | R | C | C |
| ggen synthesis packs | I | A | R | R | I |
| BLAKE3 no_std kernel | I | A/R | I | I | C |
| HCL AST diff poka-yoke | I | C | C | A/R | C |
| Lane build + per-lane commits | I | C | R | R | I |
| Migration ledger (POSH-007) | I | I | C | C | A/R |
| T4 tollgate review | A | R | C | C | R |

### 2.5 VERIFY (Weeks 11-12, tollgate T5)

| Activity | Sponsor | Arch | Beam | Go | Qual |
|---|---|---|---|---|---|
| Chicago School suites | I | C | R | C | A/R |
| Cleanroom `just posh-court` (kind) | I | C | A/R | C | R |
| Zero-drift `-detailed-exitcode` 0 | I | I | C | A/R | R |
| Mutation non-vacuity runs | I | I | C | C | A/R |
| DPMO + control plan hand-off | I | I | I | I | A/R |
| T5 tollgate + final sign-off | A | C | I | I | R |

## 3. Lane-Level RACI (Implementation Fan-Out)

Governs the DESIGN/VERIFY fan-out dispatched per POSH-010 and the
same-checkout fan-out doctrine: lanes are leases, not copies; one
canonical smalt checkout; coordinator owns every git transition.

| Activity | Coordinator | Lane Owners | Court/Skeptic Lanes | Sponsor | Qual |
|---|---|---|---|---|---|
| Lane dispatch + contracts | A/R | I | C | I | C |
| Git transitions (branch, merge, commit) | A/R | I | I | I | C |
| Disjoint lane files (L1-L8) | I | A/R | I | I | I |
| Lane build roots (`_build-lane<N>`) | C | A/R | I | I | I |
| Shared seam edits (SLA ~10 min) | C | R | C | I | A |
| Wave-1 read-only edit plans | C | R | A | I | C |
| Court/skeptic verdicts | I | I | A/R | I | C |
| Integration + verify ladder | A/R | C | R | I | C |
| Lane-lease deletion at integration | A/R | I | C | I | R |
| Escalation to Andon RED | R | R | A | I | C |

Lane laws enforced by this matrix:

- Coordinator is sole A for git state; lanes never run git state
  commands and never stash in the shared checkout.
- Lane owners are A/R only on their disjoint file set; cross-file
  minimal unblocks require disclosure in BOTH lanes' receipts.
- Skeptic/court lanes are A on verdicts and R on nothing they audit;
  a lane that builds what it audits is a conflict of interest and its
  verdict is void. Courts kill candidates; they do not pre-think fixes.
- Integration is serialized: per-lane atomic commits, lane build roots
  deleted before the integration commit.

## 4. Andon RED Escalation Path

Aligned with `andon.md` (composite signal = MAX over Build/Test/Lint/
Invariant gates, master §6). Any RED arrests the pipeline instantly.

1. **T+0 — Halt.** Gate emits RED; pipeline halts; no deploy proceeds.
   The owning role per §2 phase RACI is paged (Automated Andon).
2. **T+15 min — Triage.** Owning role classifies the defect against
   the gate's RED criteria (master §6) and files a typed defect with
   the failing court/gate receipt attached.
3. **T+1 h — Containment.** If unclassifiable or reproducibly RED:
   owning lane reverts its in-flight edit (fix-forward only; no
   `git reset --hard`); coordinator reverts the git transition if the
   defect spans lanes. Cross-lane freeze disclosed in receipts.
4. **T+4 h — Escalate to Quality Lead (A/R, gates).** Quality Lead
   decides: local repair lane (continue) or phase tollgate hold.
5. **T+1 day — Escalate to Lead Architect.** Any defect touching the
   SPAF contract (Rule 1/2/3 violation, CTQ-F) or a VACUOUS gate
   (CTQ-G) escalates immediately to Lead Architect (A on invariants).
6. **T+2 days — Escalate to Sponsor.** Any RED that holds a tollgate
   past its window, or any charter-level falsifier hit, escalates to
   Sponsor (A on phase go/no-go). Sponsor decisions recorded in the
   tollgate minutes; charter changes route through §7 change control.
7. **Return to GREEN.** Gate re-run on the repaired subject with a
   fresh receipt; a flip test (the court rejects the reverted defect)
   is required before the arrest is lifted.

YELLOW signals are warnings: logged, counted in the DPMO defect tally
(`dpmo.md`), and never silently upgraded or downgraded.

## 5. Tollgate Review Board

Composition (voting members):

- Project Sponsor — chair; holds the final go/no-go (A per master §8).
- Lead Architect (Core/Rust) — accountable for architecture and SPAF
  invariants.
- Quality/Compliance Lead (Master Black Belt) — accountable for
  verification evidence and tollgate receipts; secretary for minutes.
- BEAM Platform Engineer — consulted on BEAM-phase evidence.
- Go Membrane Specialist — consulted on adapter-phase evidence.

Quorum: all three A-holders (Sponsor, Lead Architect, Quality Lead)
present; both engineer roles may be represented by written evidence
submissions. No tollgate passes with any A-holder absent.

Evidence required per tollgate (receipts land under
`docs/jira/posh/<v>/receipts/`; ladder per `verify.md`):

| Tollgate | Required Evidence |
|---|---|
| T1 DEFINE | Approved charter + this doc family; CTQ table with
instrument + falsifier per CTQ (define.md §4); risk register seeded
from master §5 FMEA; Turtle v2.0 press release; C4 baseline. |
| T2 MEASURE | Baseline receipts for CTQ-B/D/J/K (tail latency, GC
pauses, allocations); MSA calibration receipt; N=4 defect-opportunity
map; baseline DPMO computed per `dpmo.md`. |
| T3 ANALYZE | Ishikawa diagram; FMEA with RPNs + poka-yoke map;
category-theoretic composition proof; frozen face set; seam lock in
RESOLUTIONS.md. |
| T4 DESIGN | ingress/egress Turtle specs; ggen synthesis compiling
clean; BLAKE3 kernel receipt; HCL AST diff receipt; per-ticket
acceptance green (POSH-003/004/005/007/008/009); lane-lease deletion
receipts. |
| T5 VERIFY | Chicago suites green; cleanroom `just posh-court` receipt;
zero-drift `-detailed-exitcode` 0 receipt; mutation non-vacuity
receipts (every court flips, CTQ-G); 500-run qualification tally with
DPMO 0.00 compile-time / ≤ 1.00 runtime per `dpmo.md`; control plan. |

A tollgate passes only when every listed receipt exists on disk, is
re-read at review time (not cited from memory), and names the exact
subject SHA it certifies.

## 6. Sign-Off Block

Sign-off requires ALL of the following, each verified at review time:

- All Andon gates GREEN on the final subject (master §6).
- Zero-drift falsifier green (`terraform plan -detailed-exitcode` = 0;
  CTQ-A).
- 500-run qualification tally attached, DPMO within master §7 targets.
- Open defect count at RED severity = 0 (YELLOW items itemized, not
  blocking unless CTQ-bound).

| Role | Name | Signature | Date |
|---|---|---|---|
| Project Sponsor / Executive Leadership | Sean Chatman | ______________ | 2026-10-30 |
| Lead Systems Architect | ______________ | ______________ | 2026-10-30 |
| Lead Quality Engineer (Master Black Belt) | ______________ | ______________ | 2026-10-30 |
| Principal Compliance Officer | ______________ | ______________ | 2026-10-30 |

Sign-off is void if any precondition above is unmet or if the attached
receipts do not re-verify on the sign-off subject. A partial sign-off
(signature subset) confers no approval standing.

## 7. Document Control

| Field | Value |
|---|---|
| Document | raci-signoff.md |
| Version | v26.10.30 |
| Effective date | 2026-10-30 |
| Owner | Quality/Compliance Lead (A), Sponsor (approver) |
| Review cadence | At every tollgate (T1-T5); annual minimum |
| Change control | Charter-scope changes (roles, gates, sign-off
preconditions, SPAF rules) require a new version of charter-master.md
and this document, a full board re-review, and re-signature by all four
§6 roles. Prior signed versions remain the standing record; edits after
sign-off without a new version and re-sign are void. |

## Status

RACI & SIGN-OFF — ALIVE (document). Verified this session: read
`charter-master.md` (150 lines) and `define.md` (303 lines) on disk;
master RACI transposed verbatim from charter §8; sign-off roles match
charter §9; per-phase RACI rows map 1:1 to charter §4 / define.md §5
tollgates T1-T5. PARTIAL as a project: measure/analyze/design/verify/
andon/dpmo siblings do not exist yet on disk; cross-references name
the planned files and must be re-checked when they land.
