# Xaas Prior Art — Transfer Plan for smalt

Status: transfer plan distilled from the four read-only xaas-learn surveys
(`tmp/errc/xaas-learn/{wave-ledger,governance-courts,substrate-store,wire-parity}.md`,
2026-10-15). Each item is typed:

- **adopt-now** — realizable with docs + test changes only (no lib change);
- **Raise candidate** — needs a lib change; queued for a coordinator work
  order, not landed by this lane (feature ban);
- **refused** — evaluated and rejected with the reason.

Grounding: every item cites the survey finding it comes from. smalt-side
claims were re-read on the smalt tree at write time; xaas-side claims are
cited to the survey file:line (survey falsifier: delete a cited line to
refute).

## 1. The 11 governance gaps (from `governance-courts.md` §4)

| # | Gap (xaas has, smalt lacks) | Citation | Type |
|---|---|---|---|
| G1 | **Positive controls paired with every refusal test** — each court refusal case is paired with a "with the evidence present the court admits" control, proving the court can actually pass | `governance-courts.md` §1b, `chicago_evidence_courts_test.exs:29-32` | **adopt-now** (test-side: pair new refusal fences with positive controls; existing fences paired opportunistically — witnessed: the ARM `scripts/mutation_court.py` gate-present/gate-absent phases are exactly that pairing, and the ARM lens-9 mutant kills M48/M49 each ran a red witness arm against the closed gap; docs-corpus-lens7 cycle 2 re-read) |
| G2 | **Shared refusal-atom vocabulary + mutants harness** — one `@refusal_values` typed set shared by all court test files; smalt's mutation kills are lane-local | `governance-courts.md` §4 item 2, `support/mutants.ex:20-31` | **Raise candidate** (a shared support module is a lib/test-infrastructure change; per-lane mutants remain the standing practice until admitted) |
| G3 | **Standing vocabulary fixed in one file, no-edit-without-receipt-path law** — `UNKNOWN/PARTIAL_ALIVE/ALIVE/BLOCKED/BUILD_BROKEN/UNSUPPORTED` machine-queryable; smalt cycle files use free prose ("HOLDING with re-entry conditions") | `governance-courts.md` §2, `_FRONTIER.md:8-13` | **adopt-now** (docs-side: WIRE_PARITY already uses ALIVE/PARTIAL/PLANNED with a falsifier column — this doc itself adopts the receipt-path law: a standing claim must cite its pin) |
| G4 | **Receipt-backed vs lane-reported distinction** — a status named in prose with no file on disk is "known-O, not O*"; smalt's `coordinator-unblocks.md` records admissions in prose with no file-existence gate | `governance-courts.md` §4 item 4, `_CLOSURE_RECEIPT.md` O/O* section | **adopt-now** (docs discipline: receipts cite `tmp/errc/<lane>/cycle-N.md` paths that exist on disk; coordinator prose is not a receipt) |
| G5 | **`test -f`-gated PENDING→CLOSED flips** — status transitions gate on the receipt file existing on disk | `governance-courts.md` §4 item 5, `_CLOSURE_RECEIPT.md:12-20` | **adopt-now** (same mechanism as G4, applied to any status flip in docs) |
| G6 | **Cache-refutation (cold court) schedule** — weekly re-establishment of every cached claim from nothing | `governance-courts.md` §4 item 6, `cold-court.yml:3-6` | **Raise candidate** (needs a scheduled workflow or a re-verification mix task — infrastructure, not docs; until then the ERRC lenses themselves are the manual cold court: each lens re-runs gates rather than trusting prior receipts) |
| G6' | (substrate twin of G6) **MANIFEST.sha256-style byte-identity replay fences** already exist in smalt (`runtime_contracts` MANIFEST fence) — the cache-refutation idea is partially landed | `docs/WIRE_PARITY.md` runtime-contracts row | **refused** (as a new mechanism: already present in its applicable form) |
| G7 | **Advisory-first gate landing** — new gates land `continue-on-error` with an explicit promotion path, never by editing main CI directly | `governance-courts.md` §4 item 7, `closure-gates.yml:6-14` | **refused** (smalt's gates are local `mix test` fences, not CI legs; the analog — new fences landing as lane-local suites before joining the compliance front door — is already the de-facto practice; formalizing it would add machinery to a non-CI repo) |
| G8 | **Falsifier-required-at-construction** — a falsifier that can never fire is rejected in the constructor (`fn _ -> :survived` refused) | `governance-courts.md` §4 item 8, `falsifier.ex:4-14` | **Raise candidate** (constructor-level enforcement is lib-side; docs-side adopt-now residue: WIRE_PARITY rows already name a falsifier test file — a row without one is invalid) |
| G9 | **Cross-artifact pin-consistency check** — a receipt naming a subject blob must hash-match the blob (`git hash-object` check in a script) | `governance-courts.md` §4 item 9, `check_standing_court_pins.py:41-47` | **Raise candidate** (needs a script; lane receipts already record sha256 per file and re-read them at close — the manual form is in place) |
| G10 | **Persistence court** — a test asserting a check owns zero new runtime rows/state | `governance-courts.md` §4 item 10, `chicago_evidence_courts_test.exs:17-20` | **Raise candidate** (test-infrastructure; nearest smalt analog is the crash-class "writer survives" pins in `test/security/lens5_crash_class_test.exs`, which cover the same intent for the serialized writers) |
| G11 | **Admission/actuation separation stated in the court itself** — an admission states what it does NOT authorize | `governance-courts.md` §4 item 11, `ard_court.ex:64-66` | **adopt-now** (docs-side: every coordinator unblock / transfer admission in receipts states its scope and its explicit non-authorities; this doc's Type column is that statement) |

### G6' note

The xaas cold-court idea (weekly clean re-establishment of cached claims) has
a smalt-shaped application the surveys name directly: extend the census
exit-code taxonomy (0 pass / 1 fail / 2 substrate-up-fail / 3 harness) to the
ExUnit compliance front door so a compile-abort is never read as a failure
count (`wire-parity.md` §4 item 3). **Raise candidate** (needs script or task
support).

## 2. Substrate patterns (from `substrate-store.md`)

| Pattern | xaas/ash_pplan prior art | smalt state (re-read from the tree) | Type |
|---|---|---|---|
| Reads never call the server | `ProviderRecovery` — reads do direct ETS lookup, absent-server reads answer the safe default; `catch :exit` on writes | smalt Store already answers reads directly off ETS; no change needed | **refused** (already smalt's shape) |
| `insert_new` CAS + dead-owner takeover path lock | `ash_pplan dets.ex:447-481` | smalt has `Store.insert_new/3`/`compare_and_swap/4`/`compare_and_swap_delete/3` (WIRE_PARITY Store row) | **refused** (already landed) |
| Durable-first/visible-first write ordering | KillSwitch trip writes durable-first, reset writes visible-first (`kill_switch.ex:230-254`) | smalt has no DETS/persistent_term durability tier; importing the ordering discipline only matters if a durability tier is ever admitted | **Raise candidate** (conditional: only with a durability-tier work order) |
| Sync-on-write only for mutations; reads skip sync | `ash_pplan dets.ex:100-114` | same precondition as above — applies only to a DETS twin | **Raise candidate** (conditional, same as above) |
| Bounded call contract (60s ceiling, typed `{:timeout, ...}`) | `ash_pplan dets.ex:89-98` | applies to the same durability tier; smalt Store calls are in-memory | **Raise candidate** (conditional, same) |
| Churn-safe ordered iteration via `ordered_set` seq-index | `ash_pplan ets.ex:82-84, 354-366` | smalt Store iterates via `list_prefix` — fine at smalt scale; the `ordered_set` index is an optimization, and "optimization" is not a parity claim | **refused** (no falsifiable parity gain at smalt scale) |
| Inline-handler try/rescue containment | `ocel_ash_emitter.ex:329-346` | smalt already fixed the writer-kill class (auth lens-2 cycle 1) | **refused** (already landed) |
| Hoist admission before `GenServer.call` | `sa2a bridge.ex:148-168` (the good half) | smalt refusals hoist before serialized writers (ledger existence fence inside the serialized writer was itself the lens-3 TOCTOU repair) | **refused** (already landed in smalt's shape) |
| Post-failure state treated as poisoned and dropped | `graphlaw_pool.ex:108-116` | smalt's crash-class courts already pin writer survival + usability across refusals | **refused** (already landed) |
| Size-capped sink with rotation | `ocel_ash_emitter.ex:157-176` (10 MiB cap, 2 siblings, bounded forever) | smalt's OCEL stack has no unbounded-growth surface named by any lens; no observed defect | **refused** (no falsifiable defect; feature ban) |
| Concurrent emission safe by self-contained records + strict validation (no writer sync) | `ocel_ash_emitter.ex:170-176`, `ocel_ndjson.ex:36-41` | design commentary; smalt's ETS CAS idiom already covers the equivalent surface | **refused** (commentary, not a gap) |
| Independent-source principal check | KillSwitch compares reset authority subject against an independently sourced `expected_principal` — "an authority struct's own self-reported subject is never trusted as its own proof" (`kill_switch.ex:16-57, 189-225`) | smalt auth already derives `iss` from the request authority independently (`bearer.ex:130` `request_authority/1` trusted-proxy fail-closed derivation — forwarded headers honored only under a configured trusted proxy, ignored on direct connections; WIRE_PARITY auth row) | **refused** (already landed in smalt's shape) |
| Sticky admission failure + explicit `reset/0` | `graphlaw_pool.ex:19-23, 79-89` | applies to GraphLawPool-shaped pools; smalt's GraphLaw gate is stateless per-request | **refused** (no matching surface) |

## 3. Wire/court mechanizations (from `wire-parity.md` §4)

| Pattern | Citation | Type |
|---|---|---|
| Fail-closed evidence-pack generation — a task that raises `REFUSED_EVIDENCE_PATH_MISSING` when a cited fence/receipt path is missing, and mints typed `NOT_MAPPED` instead of silence for uncovered rows | `wire-parity.md` §4 item 1, `xaas.eu_ai_act_pack.ex:22-40` | **Raise candidate** (needs a mix task; the docs-side residue lands now: WIRE_PARITY rows cite falsifier paths, and this lane's receipts cite existing file paths — the manual fail-closed form) |
| Executable anti-vacuity drift task — re-derive each C-doc row count/standing from its fence file, exit nonzero on drift | `wire-parity.md` §4 item 2, `xaas.autonomy.audit.ex:20` | **Raise candidate** (needs a mix task) |
| Typed-gap token `GAP(name)` in doc rows, machine-greppable | `wire-parity.md` §4 item 5, `eu_ai_act_pack.ex:46-90` | **adopt-now** (docs-side adoption landed 2026-10-15, docs-corpus-lens4: `docs/TEST_ISOLATION.md` tag table carries `GAP(vacuous-tag-arm-seam)` / `GAP(vacuous-tag-dp-seam)`; extended docs-corpus-lens5: `docs/WIRE_PARITY.md` now carries the convention in its header + 3 tokenized Blob-row gaps — `GAP(blob-x-ms-date-unvalidated)`, `GAP(blob-comp-lease-absent)`, `GAP(blob-error-envelope-json)` — and the Blob row's status cell corrected to PARTIAL per the file's own vocabulary; extended docs-corpus-lens-9: the Blob row now carries 4 tokenized gaps (`GAP(blob-x-ms-error-code-header-absent)` added — real Azure error responses carry the error code in that header, zero hits across `lib/` and `test/`); C1_ARM_REST.md carries 6 tokenized gaps (re-counted 2026-10-15 lens-9); C2–C7 remain flagged for the same convention) |
| Infra-failure ≠ verdict: extend census 0/1/2/3 taxonomy to the ExUnit front door | `wire-parity.md` §4 item 3, `qualify.ex:35` | **Raise candidate** (needs script support; dup of G6' note) |
| Exit-code pass-through ("failures are failures; no reinterpreting") | `wire-parity.md` §4 item 4, `stress.ex:18,43` | **adopt-now** (receipts record raw exit codes and counts, no reinterpretation — standing docs discipline) |
| Wire-court shape-consistency pins — two refusal sources pinned shape-consistent in one court | `wire-parity.md` §4 item 6, `a2a_v1_wire_deepening_test.exs:11-16` | **Raise candidate** (test additions outside this lane's surface; flagged for the owning wire lanes) |
| `@moduletag :compliance_cN` so one `mix test --include compliance` runs the whole court set | `wire-parity.md` §4 item 7 | **Raise candidate** (edits fence files — not docs; flagged for the compliance-corpus lane) |

## 4. Summary

- **adopt-now (landed by this lane / standing docs discipline)**: G1, G3,
  G4, G5, G11, exit-code pass-through, plus the docs residue of G8/G9 and the
  fail-closed evidence-path law (this doc's citations are all disk-verified
  paths).
- **Raise candidates (coordinator admission required, lib/task/test-infra)**:
  G2 (shared mutants module), G6/G6' (cold court, ExUnit exit taxonomy), G8
  (constructor falsifier gate), G9 (pin-consistency script), G10 (persistence
  court), durable-first/visible-first ordering + sync-only-mutations +
  bounded calls (conditional on a durability-tier work order), fail-closed
  pack generation, anti-vacuity drift task, typed-gap tokens in the
  compliance-corpus C-docs (C1_ARM_REST.md landed with 6 tokens — see §3;
  C2–C7 still pending with the compliance-corpus lane),
  shape-consistency courts (wire lanes), `@moduletag :compliance_cN`
  (compliance-corpus lane).
- **refused**: G7 (advisory-first CI gates — no CI legs in smalt), G6' as a
  new mechanism (MANIFEST fence already the applicable form), and every
  substrate pattern smalt already implements (reads-off-server, insert_new
  CAS, inline-handler containment, hoisted admission, poisoned-state drop,
  independent principal derivation) plus the no-defect optimizations
  (ordered_set index, sink rotation) — refused under the feature ban and the
  no-defect-no-change law.

Falsifier for this doc: every xaas-side citation is `tmp/errc/xaas-learn/<file>.md`
(section-quoted); every smalt-side claim cites a repo path or WIRE_PARITY row
re-read 2026-10-15. Deleting a cited survey finding or showing a cited smalt
path diverges from the tree refutes the corresponding row.

## See Also

- `docs/WIRE_PARITY.md` (GAP-token convention, falsifier-pinned rows)
- `docs/TEST_ISOLATION.md` (GAP tokens in the tag table)
- `docs/how-to/dev-loop.md` (status-flip discipline — G4/G5 adoption)
