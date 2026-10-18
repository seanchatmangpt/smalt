# NEXT WINDOW — planning handoff from v26.10.16 (terminal revision)

Source: verified carries from the v26.10.16 wrap (`WRAP_LEDGER.md`,
`FINAL.md`, `PUBLISH_RECORD.md`, `PROJECTION-ARCH-PLAN.md`) plus the
v26.10.17 projection opening already landed on main. Reconciled against
the on-disk tree at main, 2026-10-17 (HEAD `650a8ff`); counts and
statuses re-read from disk at this edit — stale-by-default law applies
at execution time.

## 1. LANDED this window (do not re-queue)

| Item | Evidence on disk |
|---|---|
| W1 foundation — ConfigKey + StoreTable ontology projections (Smalt.Config 46 keys; Smalt.StoreTables 33 owned + 19 shadow; swept-but-unowned bug class closed; replay fences 10/0) | commit `8361816`; `lib/smalt/config.ex`, `lib/smalt/store_tables.ex`, `test/config_replay_identity_test.exs`, `test/store_tables_replay_identity_test.exs` |
| W2 — CascadeEdge projection (23 rows, every `sweepStrategy!=none` table declared) | commit `6dc0013`; `lib/smalt/cascade_edges.ex`, `test/cascade_replay_identity_test.exs` |
| W2 — semconv pack projection (kills the hand-sync fence) | commit `6dc0013`; `lib/smalt/telemetry/semconv/registry.ex` (ggen-projected from `../ggen-marketplace/packs/smalt-semconv-pack`), wiring in `mix.exs`, fences `test/semconv_test.exs` |
| W2 — Canonical riders (THIRD_PARTY renderer + capabilities identity block) | commit `6dc0013`; `lib/smalt/projection/canonical.ex`, `docs/THIRD_PARTY.md`, `docs/capabilities.json`, `test/canonical_projection_test.exs` |
| KD-94 (cosmos AAD auth shape) flip | CLOSED-SIMULATED, witness `docs/jira/v26.10.16/receipts/r231-kd94-uppath-witness.md`, commit `16a753b` |
| mcp_wire doctor-agreement fix (connect-probe) | fix effective, fence green solo `1 test, 0 failures` — `docs/jira/v26.10.16/WRAP_LEDGER.md` "mcp_wire doctor-agreement surface"; deterministic class empty at close |
| ERROR_CODES extractor extension (arm-gateway PolicyViolation + egress InvalidEventGridEvent; `--check` drift fence) | `scripts/gen_error_codes.py`; `python3 scripts/gen_error_codes.py --check` → "docs/ERROR_CODES.md up to date", exit 0 (WRAP_LEDGER run-20 row) |
| Engine law — graphlaw fixed, no engine selection (sparql + qlever deleted) | commit `9700981`; `docs/jira/v26.10.16/PROJECTION-ARCH-PLAN.md` §4 |
| SMALT_MAX_CASES degraded-host law | commit `225d8e2` |
| Docs first-principles rewrite (inventory DAG, README, reference, explanation) | commit `c6e7f93`; receipts `docs/jira/v26.10.16/receipts/lane10-explanation-rewrite.md`, `docs/jira/v26.10.16/receipts/lane9-reference-rewrite.md` |
| KD-89 PQC closure (ML-DSA-65 engine-adjudicated forge court) | CLOSED-WITH-RECEIPT, witness `docs/jira/v26.10.16/receipts/kd89-ml-dsa-closure.md`, commit `4d8a0e7`; NOTE: this closed the **forge half** — the ledger-attestation half stays open (§3.3) |
| Fin sweep, 4-generator idempotence | `docs/jira/v26.10.16/receipts/final-fin-sweep.md` (ALIVE, RI-IDEMPOTENT) |

## 2. Opening queue — v26.10.17 projection waves (from
`PROJECTION-ARCH-PLAN.md`, engine law fixed)

Dependency-ordered. Waves W1/W2/semconv already landed (§1); the
remaining order per D1:

1. **HashChainLedger projection (W3 ledger half, not yet landed)** —
   no `HashChainLedger` module exists in `lib/smalt` (grep verified
   2026-10-17); ledger_writer + confidential_ledger (~70%) remain
   hand-written. Close: `ledger.receipt` + replay fence + sentinel
   under the discipline, per plan §1 W3.
2. **Shim-courts scaffold (W4, first projected code)** — 1 template +
   25 rows; 25 files / 3,178 LOC → template + rows; first production
   exercise of `Actuate.write_new_file!`. Close: `shim_courts.receipt`
   + replay fence on all 25 rendered files.
3. **KD-fence + corpus scaffold (W5)** — KD fence from the 94-row
   register; corpus families 1 template + family rows; gate/verify
   pairing convention. Close: `kd_fences.receipt`, `corpus.receipt`.
4. **Route shells, family-by-family (W6, D3 behavioral-equivalence
   law)** — EG topics (8 macros) → storage/KV getters → azapi actions →
   roleAssignments/policy → parented-child shells; per-family court
   ladder green + receipts before each hand-written deletion; D3b
   ontology-declared priority ordering. Close: per-family receipts +
   cumulative arm_lines_deleted counter — canonical counter home is
   `docs/jira/v26.10.17/COUNTERS.md` (seed 0; derivation command there,
   numbers re-derived at execution time, never restated from prose).
5. **sjira ProjectionSpec backend (W8, depends on W4; W6
   recommended)** — `:projection` backend per plan D4; sj:CodeKind
   byte-fence upgrade; falsifier→verify-gate projection. Close:
   `projection_backend.receipt`; end-to-end demo WO renders, gates,
   reconciles without hand touch.
6. **ERROR_CODES judgment call (W9, deferred)** — codes as ontology
   individuals projecting docs table + emitting code; land only after
   W2/W6 hardened the engine; decision at the W9 gate: land variant
   (a) or stand down with a verify query asserting ERROR_CODES.md is a
   rider of the codes file.
7. **provider-matrix / cascade verify-pairing authoring** (carried —
   the `gates/0XX_*.rq` ↔ `verify/*.unbound.rq` pairing convention is
   still unfilled for provider-matrix and cascade-dispatch). Close:
   verify pairings authored, negative fixture (violated pairing refuses
   generation, exit nonzero) receipted.

## 3. Release-gate carries (still open, close conditions attached)

1. **Court two-green on a settled host.** Ledger at close: **32
   completed invocations, 0 two-green** (supersedes the 30-invocation
   line; runs 30-32 witnessed — run-30 red receipt
   `docs/jira/v26.10.16/receipts/r226-court-x2-run30-red.md`
   (`COURT_X2_RC=1`, shifting-failure FLAKE_SOLO residual); terminal
   run-32 per `tmp/court-x2-wrap-run32.log`: run 32.1 completed TYPED —
   `2457 tests, 7 failures`, drift-fence class on the W2-late surface
   that landed as `b6a8b7e` — run 32.2 aborted at `just doctor`
   port-in-use). Residual
   classes (WRAP_LEDGER runs 13-21 post-mortem): (a) Enclave.Lifecycle
   ordering pair (recurred runs 6/9/15/19 — dominant face), (b)
   solo-green churn bursts (SealTest, SemanticProjection, StoreChurn,
   LockManager, Lens5Fuzz), (c) environment/infra: orphan port holds
   (runs 11/16) + compile-freeze transient. Close: first both-green
   invocation with a successor witness receipt (r216 name is taken by
   two typed-RED receipts); RELEASE_NOTES standing flip receipt-gated
   on it — no court-x2 receipt, no flip.
2. **ex4pm hex auth + dual-pin flip (publish B1/B2).** ~~B1 half: publish-dry
   TYPED-BLOCKED on ex4pm-not-on-hex; cross-repo close owned by the ex4pm
   repo~~ — **B1 DONE (2026-10-17)**: ex4pm 26.10.8 live on hex.pm; smalt
   `mix.exs` hex dual-pin flipped (d-date 2026-10-17); `mix hex.build` exit 0.
   Witness: `docs/jira/v26.10.17/receipts/r244-publish-record.md` (closes
   PUBLISH_RECORD.md B1 and §4-table item 10). REMAINING OPEN (not closed by
   B1): `mix hex.publish --dry-run` exit 0 or per-warning disposition receipts;
   NOTICE.md upstream license/attribution block (verified absent 2026-10-17);
   sub-item (b) AshR2RML prod-compile re-check post-pin-flip; sub-item (c)
   `stream_data` `only: :test` retarget (B3).
3. **PQC ledger-attestation half (KD-89's ledger half).** The forge
   half is CLOSED (§1); the ledger-level GAP is unchanged: the
   attestation surface is classical-only (SHA-256 Merkle + RS256 JWS
   receipts) — `docs/jira/v26.10.16/FINAL.md` "PQC gap, honestly
   stated". Close: ledger receipts carry PQC-rooted attestations (or a
   registrar-minted token registers the divergence with its close
   condition).

## 4. §13 reconciliation — what is genuinely still open

Re-read from the canonical register and tree at this edit:

| Old §13 item | Status at this edit |
|---|---|
| 1. Affidavit upstream WO (ML_DSA65 verify op, CTRT witness region, reproducible rebuild) | forge half **DONE** (KD-89 closed, artifact re-pinned `b3cf38ba…`); remainder: reproducible two-target rebuild + CTRT witness-region population upstream — carry as §3.3 ledger-half carry |
| 2. KD-90 in-process blake3 NIF | **OPEN** (canonical row: OPEN, perf divergence, bench-pinned `docs/jira/v26.10.16/bench/affidavit-seal.jsonl`) |
| 3. tf-tier retirement | **DONE** (recorded decision, §12 of prior revision) |
| 5. KD-84/85/86 SB fixes | **ALL OPEN** (canonical rows read 2026-10-17: settlement-race flush, `x-opt-enqueued-time` key, auto-ensure typed default; falsifiers embedded in the rows) |
| 6. KD-COVERS retokenize KD-82 → KD-87 | **OPEN, partial referent drift**: `lib/smalt/arm_gateway/router.ex:77` still carries `KD-COVERS: KD-82`; `lib/smalt/arm_gateway/bearer.ex` **no longer exists on disk** — re-locate the second site (if any) before retokenize |
| 7. ERROR_CODES extractor extension | **DONE** (§1) |
| 8. ash_extension manifest hand-adapted provenance | **OPEN** (no receipt on disk names it; 3 stale manifest entries per the lane-16 finding) |
| 9. `--check` modes for the three generators | **OPEN** — `scripts/receipt_index.py` has documented idempotence (`final-fin-sweep.md`, RI-IDEMPOTENT) but no `--check` flag; `scripts/bench_report.py` does not exist under that name on disk — re-inventory the actual generator scripts before authoring |
| 10. ex4pm dual-pin | ~~**OPEN** (now §3.2)~~ **DONE (2026-10-17)** — ex4pm 26.10.8 live on hex.pm; smalt `mix.exs` hex pin `{:ex4pm, "~> 26.10.8", override: true}` flipped (d-date 2026-10-17); `mix hex.build` exit 0. Witness: `docs/jira/v26.10.17/receipts/r244-publish-record.md` (also closes PUBLISH_RECORD.md B1; §3 item 2 remainder = NOTICE upstream-attribution + B3/B5/B6 dispositions, unchanged). |
| 11. KD-91 ARM CheckNameExists | **OPEN, witness-pending** (fix landed `lib/smalt/arm_gateway/router.ex:4410-4420`; flip receipt-gated) |
| 12. KD-92 ARM/data-plane container store split | **OPEN** (mirror-or-shared-store fix + falsifier probe; flip receipt-gated) |
| 13. KD-93 cosmos query feed scope/freshness | **OPEN** (falsifier probe: `WHERE c.mark = @mark` must return the just-written doc; flip receipt-gated) |
| 13b. provider-matrix/cascade verify-pairing | **OPEN** (now §2.7) |
| 14. hex.publish remediation | **OPEN** (folded into §3.2) |
| 15. priv-asset cwd-relative boot paths → `:code.priv_dir(:smalt)` | **OPEN** (no receipt names it; referents `lib/smalt/tls.ex`, `lib/smalt/enclave/doctor.ex`, `lib/smalt/enclave/lifecycle.ex`, `lib/smalt/affidavit/wasm_engine.ex`) |
| 16. `:inets`/`:xmerl` orphan extra_applications | **OPEN** (census-then-remove-or-note) |
| 17. Mix.Tasks placement under `lib/smalt/dspy/tasks/` | **OPEN** |
| 18. semantic_epoch lenient reads | **NOTE-ONLY** (documented degradation; no close condition; do not re-queue) |

Also still open from the prior file (unreconciled items verified
unlanded):

- **§14 ERRC residuals** 1 (compiler-based unused-module census: verify-first
  candidates unchanged), 2 (KD-53 batch-callback fence test — row
  CLOSED-SIMULATED; the fence test half is the open half), 3
  (ts-event-hubs re-probe), 4 (`scripts/tf_provider_wrap.sh`
  kill-or-wire), 5 (`docs/audit/` staleness), 6 (PACK_INTEGRATION
  census), 7 (`scripts/__pycache__` ignore), 8 (wave-telemetry roll-up:
  coordinator decision).
- **§9 wire-parity parks** — carried verbatim, unchanged: SB
  reply_to/reply_to_session_id drop; SB subscription rules/filter
  engine absent; atom_bridge QueueDescription optional-field gaps (§4
  probe-authoring of the prior revision carries the work order);
  `GAP(blob-comp-lease-absent)`, `GAP(blob-x-ms-date-unvalidated)`,
  delete_blob WORM-before-If-Match precedence divergence,
  `GAP(cosmos-sql-translator-absent)`, `GAP(eventgrid-eg1-schema-absent)`,
  `GAP(kql-datetime-dynamic-types-absent)`,
  `GAP(atlas-search-relationship-get-absent)`.
- **§3 SUSPECT triage remainder** (historical-accept vs leave-flagged
  disposition receipt; re-count from `receipt_index.py` at execution
  time — index reads 16 SUSPECT at the fin sweep, stale-by-default).
- **§4 QueueDescription probe-authoring rows** — still the close path
  for the atom_bridge gaps.
- **§5 `use Plug.Test` deprecation lint** — first action remains
  capturing the real warning output; a lint fix without a witnessed
  warning is an unverified premise.
- **"Queued from v26.10.16 console + capability wave"** residuals not
  covered above: Event Grid webhook delivery leg; system-topic-sourced
  event ingest; EH namespace-scoped consumergroup list-all; console
  Ring 3/4 remainder (resourcegraph, LRO, monitor views);
  Elixir PATH pin (1.20.3) for lanes.
- **KD-60/77/82 flip-court witnesses**: KD-77 repair landed with
  witness `docs/jira/v26.10.16/receipts/r210-kd77-delivery-tag.md`
  (PARTIAL_ALIVE, one loud skip); row flip still pending
  `scripts/kd_flip.py --apply` receipt-gated.
- **§10 wave-surfaced register candidates** — six candidates, each
  acted on or explicitly re-parked by the opening wave; no silent drop.

## 5. A-wave residuals

The A-wave was the v26.10.16 audit-lane fan-out (A1-A13, per
`docs/jira/v26.10.16/_LANES.md`). Residuals on disk:

- A12 doc-vs-referent audit class: the
  `ash-kudzu-integration.md` numbers correction is recorded in
  FINAL.md §Certification (41 admitted types = module-attribute ground
  truth); any further number drift is a standing audit class, re-run
  doc-vs-referent at the next wrap.
- **SOC2 wording**: no on-disk referent for any SOC2/SOC 2 item exists
  anywhere under `docs/` (grep verified 2026-10-17, zero hits). If the
  coordinator's "SOC2 wording done" refers to a release-announcement
  wording pass, it landed without a receipt — treat as
  no-referent-unless-named; do not cite it as receipted work.
- Court residual classes named in §3.1 are the A-wave's open repair
  surface (the churn/ordering/infra families the audit lanes
  surfaced).

## 6. Execution order (dependency)

1. §2 opening queue in order (HashChainLedger → W4 → W5 → W6 → W8 →
   W9), each wave with its own receipts + replay fences.
2. §3.1 court two-green (runs alongside; the release-receipt mint and
   RELEASE_NOTES flip stay gated on it).
3. §4 KD flips (KD-77, KD-91) — receipt-gated, `scripts/kd_flip.py
   --apply` only.
4. §3.2 ex4pm hex → dual-pin → publish-dry unblock (cross-repo,
   operator-owned).
5. §4 ERRC/§9/§10 residuals — schedule per lane after the opening
   queue is partitioned into `_LANES.md`.
6. §6-of-prior-revision FINAL.md handoff pointer: superseded — this
   file IS the terminal handoff; the v26.10.17 window mints its own
   NEXT_WINDOW at wrap.
