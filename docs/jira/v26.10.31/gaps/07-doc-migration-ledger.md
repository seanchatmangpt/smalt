# GAP-07: Doc-migration ledger — executed checklist (v26.10.31)

Lane 7 of 15. Applies GAP-15's Tier A/B/C classification as a tracked
checklist the coordinator executes at close time. This lane performed **no
corpus edits**; its only corpus action was the grep verification receipted
below.

- Source plan: `docs/jira/posh/v26.10.31/gaps/15-doc-migration-plan.md` (ALIVE, 2026-10-30)
- Decision record: `docs/jira/posh/v26.10.31/00-unification-dialect-decision.md` (ALIVE, DECIDED, 2026-10-30)
- Corpus root: `docs/jira/posh/v26.10.30/`

## Grep verification receipt (2026-10-30)

Run from the corpus root:

```
grep -c "00-unification-dialect-decision" README.md requirements-synthesized.md \
  POSH-004-terraform-provider-go.md POSH-003-azure-arm-client.md \
  POSH-009-sdk-parity-register.md working-backwards.md gaps/01-provider-azurerm-parity.md
```

Result: `0` for every named file, **exit 1** — no backlinks anywhere.

```
grep -rn "NEUTRAL-CORE\|DIALECT-SCOPED" . --include="*.md"
```

Result: **zero files match**, exit 1 (corpus-wide, includes dfcharter/).

Conclusion: **no prior lane has landed any Tier A section, Tier B stamp, or
decision-record backlink.** Every row below is PENDING. The exit-gate court
currently stands at 0 of 3 mandatory backlinks — it FAILs if run today.

> **Wave-2 update (2026-10-30, lane 15):** the receipt above is the pre-edit
> baseline and stands as written. All 9 Tier A/B rows have since been landed
> (statuses flipped to DONE below); the exit-gate Current column now reads
> 1 each with Gate MET. Close-time court re-run + anti-vacuity mutation
> remain coordinator close actions.
>
> **Wave-2 reconciliation re-run (2026-10-30, gap lane 07):** independent
> fixed-string re-grep this session confirms all 9 rows landed. Actual
> backlink counts are higher than the "1" above: README.md=3,
> requirements-synthesized.md=2, POSH-004=1 (POSH-003=1, POSH-009=1,
> working-backwards.md=1, gaps/01=1). Note: `grep "A\|B"` alternation under
> ugrep treats `\|` as a regex group — use `grep -F` for literal stamps; the
> pre-edit baseline receipt's zero counts were reproduced only with the
> alternation form and are historical.

## Tier A — gains a NEUTRAL-CORE section (v26.10.31)

| Doc | Tier | Exact edit owed | Status |
|---|---|---|---|
| `dfcharter/charter-master.md` | A | New section "Neutral core (v26.10.31)": Port In = dialect-facing ingress of the membrane; Starboard = smalt-core-facing egress; turnstile = mutation-receipt fence; dialect = vendor translation layer living in posh. Terms get core IRIs in smalt-core.ttl when it lands (lanes 9/13 feed). | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `requirements-synthesized.md` | A | New section "Dialect layer (v26.10.31)": the Go adapter's shims reclassify as dialect faces; neutral-core admission layer sits above registry families; cross-ref `../../posh/v26.10.31/00-unification-dialect-decision.md`; reclassify ARM = dialect #1, STS = dialect #0. **Also mandatory backlink target #2.** | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `glossary.md` | A | Prepend a NEUTRAL-CORE block defining Port In, Starboard, turnstile, dialect, dialect #0 (identity), dialect #1 (Azure ARM), smalt-core.ttl; keep the existing Azure table as the dialect-#1 sub-glossary under a renamed heading, not the whole glossary. | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `README.md` (POSH section) | A | Header cross-ref: "Dialect decision: `../v26.10.31/00-unification-dialect-decision.md` — the azurerm swap is dialect #1, not the core"; POSH-003/004 rows marked DIALECT-SCOPED. **Also mandatory backlink target #1.** | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |

Tier A tally: 4 rows, 4 done, 0 PENDING.

## Tier B — becomes DIALECT-SCOPED stamps (additive; no operator text rewritten)

| Doc | Tier | Exact edit owed | Status |
|---|---|---|---|
| `working-backwards.md` | B | Additive "Dialect scoping note (v26.10.31)" header block: press-release claims are dialect-#1-scoped (azurerm swap) and dialect-#0-scoped (Entra STS). Operator-supplied text stays verbatim; core-level equivalents are v26.10.31 charter items, never edits to operator text. | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `gaps/01-provider-azurerm-parity.md` | B | Stamp "DIALECT-SCOPED: dialect #1 (Azure ARM/azurerm)". Close condition stays azurerm-scoped; a neutral-core role-definition row gets a forward pointer, not a fix here. | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `POSH-003-azure-arm-client.md` | B | Stamp DIALECT-SCOPED (dialect #1, consumes dialect #0 STS) + header cross-ref to the decision record. | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `POSH-004-terraform-provider-go.md` | B | Stamp DIALECT-SCOPED (dialect #1) + header cross-ref to the decision record (task-mandated). Stamps additive; acceptance criteria stay byte-identical in meaning. **Also mandatory backlink target #3.** | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |
| `POSH-009-sdk-parity-register.md` | B | One-line stamp: parity target is "the dialect-#1 surface"; gate semantics unchanged. | **DONE** (2026-10-30, lane 15 wave-2: edit landed, grep-verified) |

Tier B tally: 5 rows, 5 done, 0 PENDING.

## Tier C — unchanged (dialect-independent already)

| Doc | Basis | Status |
|---|---|---|
| `dfcharter/triz.md` | Operator-supplied, authoritative; contradiction matrix is membrane-level (Principle 24 intermediary); no vendor surface in its laws (1 "Azure" mention, grep -c = 1). | UNCHANGED (no action) |
| `exit-codes.md` | Per-script-family PASS/FAIL/SKIP matrix; court mechanics, vendor-free. | UNCHANGED (no action) |
| POSH-001, POSH-002, POSH-005, POSH-006, POSH-008, POSH-010 | Scaffold, membrane protocol, packaging, courts, fences, wave plan — membrane-level, vendor-free acceptance criteria. POSH-008's allowlist (posh.yaml) is the ceiling in decision-record law 3; nothing Azure-named. | UNCHANGED (no action) |
| `dfcharter/` process docs (define/measure/analyze/design/verify/andon/dpmo/raci-signoff) | DMADV process records; vendor-free. | UNCHANGED (no action) |
| `schema-v1.md` | Already the dialect-#1 schema of record; wholly swap-scoped by construction — no edit. | UNCHANGED (no action) |

Tier C tally: 5 rows, 0 edits owed.

## Exit gate — backlink court (coordinator runs at close time)

The decision record `docs/jira/posh/v26.10.31/00-unification-dialect-decision.md`
must be cross-referenced from exactly these three mandatory locations:

| # | Location | Verify command | Current (2026-10-30, post-wave-2) | Required | Gate |
|---|---|---|---|---|
| 1 | `v26.10.30/README.md` POSH section | `grep -c "00-unification-dialect-decision" docs/jira/posh/v26.10.30/README.md` | 1 (landed 2026-10-30) | >= 1 | MET |
| 2 | `v26.10.30/requirements-synthesized.md` | `grep -c "00-unification-dialect-decision" docs/jira/posh/v26.10.30/requirements-synthesized.md` | 1 (landed 2026-10-30) | >= 1 | MET |
| 3 | `v26.10.30/POSH-004-terraform-provider-go.md` | `grep -c "00-unification-dialect-decision" docs/jira/posh/v26.10.30/POSH-004-terraform-provider-go.md` | 1 (landed 2026-10-30) | >= 1 | MET |

Court rules (per GAP-15):

- < 3 mandatory backlinks at close time ⇒ **FAIL**.
- Corpus-wide sweep must also show **no un-stamped Tier B doc** — a Tier B
  doc without a `DIALECT-SCOPED` stamp fails the gate (exit 1).
- Anti-vacuity mutation: remove one Tier B stamp in a temp copy; the court
  must flip to FAIL. A court that cannot flip is FAIL.
- Read-only + temp copy; the court never writes the corpus.

## Wave-2 reconciliation — non-doc landings (verified on disk 2026-10-30, gap lane 07)

Every claim re-verified by this lane's own grep/ls this session (one artifact
spot-check per row).

| Item | Lanes | Status | Evidence |
|---|---|---|---|
| KD register `dialect` column | 18 (kd-registrar) | **LANDED** | `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:15` — header `id \| dialect \| surface \| divergence \| evidence receipt \| close condition \| status`; 185 rows stamped `AZURE-#1`/`CORE` (grep -c, this session); `docs/jira/v26.10.31/KNOWN_DIVERGENCES.md:9-13` — pointer doc registers KD-187 (CLOSED-OBSOLETE, stale-image falsifier; receipt `receipts/kd187-stale-image-falsifier.md`) and KD-188 (registration-only). |
| ttl canonicalization + 9 shapes | 5/8 | **LANDED** | `priv/ontologies/public-cloud-core.ttl` — exactly 9 `a sh:NodeShape` (lines 23, 62, 98, 133, 201, 240, 271, 305, 332); M13's proprietary-IRI falsifier grep `smalt.dev\|Microsoft/\|azure` over the ttl → 0 matches; input shard `docs/jira/v26.10.31/gaps/02-p1-core-ttl-shard.md` (7 shape requirements, each with a refusal falsifier). |
| Dialect package | 10–12 | **LANDED** | `posh/internal/dialect/` — `dialect.go:116-122` (TurnstileReceipt fails closed, POS-008), `lower.go`, `azure/` (azure.go, sts.go, routing.go, lro.go, families.go, families_registry.go, error_envelope.go; subpkgs `armkv/`, `kv7/`, `pinion/`; courts `wire_court_test.go`, `routing_court_test.go`, `lro_parity_test.go`). |
| Receipt v2 | 17 | **LANDED** | `posh/internal/receipt/` — `blake3.go:4` (BLAKE3 receipt digest; cites the v26.10.30 contract from working-backwards.md + design.md §5.1), `verify.go`, `blake3_test.go`; digest threading law at `lib/smalt/posh/turnstile.ex:16` (raw request body → Settlement BLAKE3 digest). |
| Pin split | M12 | **LANDED (executed)** | `compat-pin-core.ttl` (1,790 B) + `adapters/terraform-provider-smalt/compat-pin.ttl` (5,687 B) on disk, monolith `compat-pin.ttl` retired (absent at repo root); `docs/jira/posh/v26.10.31/gaps/12-compat-pin-split.md` status "ALIVE — split executed 2026-10-30" with court witness (core leg exit 1 on surfaceCount mutation, dialect leg exit 1 on acr mutation, loud-skip exit 3 on missing dialect pin, court exit 0). |
| Tripwires | M17 | **SPLIT: enforced + PLANNED** | Enforced: `scripts/must_not_migrate_gate.py` on disk (18,440 B, mtime 2026-10-30 16:05). `docs/jira/posh/v26.10.31/gaps/17-what-must-not-migrate.md:76-87` — F1/F2/F2b enforced; T1 (poshvet extension), T3 (charter-conformance court), T4/T5 accretion detection PLANNED. Owner: wave-3. |
| Byte-identity guard run | M16 | **PARTIAL** | `docs/jira/v26.10.31/receipts/m16-byte-identity-guard-run.md` — leg 1 ALIVE (vitest harness 8/8, exit 0); leg 2 BLOCKED (terraform plan exit 1, backend reinit required in consumer repo, outside lane lease); leg 3 typed SKIP (exit 3, loud, guard-spec premise rot recorded). Owner of the unblock: coordinator. |
| Credential model | M9 | **PARTIAL** | `docs/jira/posh/v26.10.31/gaps/09-credential-model.md` — census ALIVE (718 doc hit-files + ~260 non-docs hit-files classified, appendix path on disk); phase-1/2 close conditions (hermetic canary, dialect-1 byte-identical court, second-dialect court) and phase-3 face inversion UNEXECUTED. Owner: wave-3 / lane 16 sequencing. |
| Admission shards | M2/M13 | **SPLIT: shard landed, admission open** | M2: `docs/jira/v26.10.31/gaps/02-p1-core-ttl-shard.md` — 7 shape requirements landed as DRAFT input; lane 8 merged them into the core ttl; admission-corpus close condition BLOCKED-on-merge (three-artifact `mix smalt.gen` + replay-identity fence runs post-merge). M13: `docs/jira/posh/v26.10.31/gaps/13-admission-split.md` — design PARTIAL_ALIVE; **57**/57 admitted types map to exactly one core class, count-verified exit 0 (H4's "58" recorded as a typed census correction); phases 1–3 UNEXECUTED. Owner: lane 16 P1, post-merge. |

### Open rows and owners (snapshot 2026-10-30, gap lane 07)

1. **Exit-gate anti-vacuity flip** — remove one Tier B stamp in a temp copy;
   court must FAIL. Only un-witnessed court step. Owner: coordinator (close time).
2. **M16 leg 2 unblock** — `terraform init -reconfigure` in
   `courtroom-platform-az`; state-touching, outside lane lease. Owner: coordinator.
3. **M17 tripwires T1/T3/T4/T5** — PLANNED. Owner: wave-3.
4. **M9 phases 1–3 close conditions** — UNEXECUTED. Owner: wave-3 / lane 16.
5. **M13 phases 1–3** (`registry_core.ex` generation, coverage assertion,
   dialect-type projection) — UNEXECUTED; admission-corpus close
   BLOCKED-on-merge. Owner: lane 16 P1 / post-merge.
6. **Core IRIs for Port In / Starboard / turnstile / dialect** —
   charter-master's landed section promises them "when smalt-core.ttl lands";
   the ttl is now on disk (9 shapes), IRIs not yet added. Owner: wave-3
   (charter feed, lanes 9/13).

## Status

- Tier A/B/C classification applied to per-row checklist: **ALIVE** (this file).
- Grep verification of the three mandatory backlinks and the stamp sweep:
  **ALIVE** (receipted above, run 2026-10-30 from `docs/jira/posh/v26.10.30/`).
- All Tier A sections and Tier B stamps: **DONE** — landed 2026-10-30 by
  lane 15 wave-2 (9 rows: 4 Tier A sections, 5 Tier B stamps, all additive;
  grep receipts below).
- Exit gate: **PASS on lane-15 receipt; confirmed by gap-lane-07 re-run** —
  3 of 3 mandatory backlinks present (re-grepped this session: `README.md` 3,
  `requirements-synthesized.md` 2, `POSH-004` 1); 5 of 5 Tier B docs stamped
  (`grep -rlF "DIALECT-SCOPED"` matches all five; `working-backwards.md`
  carries its planned scoping note instead, landed at `:12`).
  Coordinator re-runs the court at close time; anti-vacuity mutation still
  owed at close (remove a stamp in a temp copy, court must flip).
- Wave-2 non-doc landings reconciled (section above): KD dialect column, core
  ttl (9 shapes), dialect package, receipt v2, M12 pin split — **LANDED**;
  M17 tripwires, M16 guard run, M9 credential model, M2/M13 admission shards
  — **SPLIT/PARTIAL** with named owners (open rows 2–6).
- This file is the reconciliation lane's only write this session; zero corpus
  files touched by lane 07.
