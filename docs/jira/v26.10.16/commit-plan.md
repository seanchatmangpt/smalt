# Commit Plan — 9-family atomic staging (F-7)

Draft commit messages for `scripts/stage_atomic_commits.sh` (FAMILIES order:
bench, shims, errc, planning, receipts, gates, audit, repo, tools — fixed by
the script, not negotiable). Family membership is whatever
`stage_atomic_commits.sh --dry-run` classifies from `git status --porcelain`
(dry-run re-verified 2026-10-16: 47/89/32/11/81/2/2/8/12 files, zero
UNMATCHED). Messages are installed into the script's `write_msgs()` before
execution; each goes through `git commit -F /tmp/stage-msgs/<family>` per repo
convention. Receipt citations below point into
`docs/jira/v26.10.16/receipts/` unless prefixed with a window.

---

## 1. bench

```
bench(v26.10.16): bench harness, lanes and results regenerated post-repair

- scripts/bench/ lane updates (n7_sse_herd, topo-worker, c8 chaos overlay,
  report.py fail-closed A/B) + scripts/wave_telemetry.sh CLEAN holes
  (R177f 2a/2b markers, receipts/r163b-clean-hardening-e1-e4.md wave-telemetry legs)
- v26.10.14 bench jsonl refresh: a1/b8/c7/c8 re-run lanes + full n-lane
  set (n1-grid..n8-soak) with per-lane receipts under
  docs/jira/v26.10.14/receipts/ (a1-change-feed.md, n7-sse-herd.md, ...)
- BENCH_RESULTS.md regenerated via `just bench-report` (generated
  artifact, not hand-patched)
- c6 corpus correction receipted (receipts/r103-c6-corpus.md,
  receipts/r117-c6-sentinel-rg-loud-skip.md: loud-SKIP exit 3)
- r103 SKIP stands loud (azure.monitor absent, no offline mode) —
  never a faked pass
```

## 2. shims

```
feat(shims): wire fences, KD closers and shim-court surface (AMQP, blob, cosmos, egress, TLS)

- KD flips closed with witnesses: KD-53 EH batch dup-section-KIND
  (receipts/r185e-eh-batch-dup-kind.md), KD-68 selector-filter
  (receipts/r200d-kd68-selector-impl.md), KD-76 pk-routing impl →
  real-SDK FAIL witness → repair (r200e/r200g/r200h), KD-46
  deferred-redelivery deliveryCount (receipts/r200f-kd46-mgmt-surface.md),
  KD-70/71 delivery_annotations + x-opt-* (receipts/r200a-kd70-delivery-annotations.md,
  receipts/r200b-kd71-xopt-props.md)
- new shim courts: atom_bridge, disposition_token, ets_cleanup,
  amqp_framing, settle_cas, blob_worm_arms, renew_mirror,
  conftest_proc_guard, tombstone_grace, eh_batch, comp_whitelist
  (re-anchored, receipts/r151-comp-whitelist-reanchor.md)
- wire fences W1-W3 + mgmt entity names + lock ABA CAS
  (receipts/r155-wire-fences-w1-w3.md, receipts/r144-lock-aba-telemetry-read-guard.md,
  receipts/r135-r137-r138-mgmt-names-path-fence-kv-colon.md)
- blob/cosmos/KV/TLS repairs: HEAD-DELETE splat default-deny (r122),
  PUT=replace (r118), etag=f(body) (r134), create-time metadata (receipts/r77-blob-create-time-metadata.md),
  SPKI verify_pair + TLS pin (receipts/r174-tls-trio-fuzz-nonrepro.md), KV colon-name
  collision fence (r138)
- egress: comp-envelope dedup + sentinel quote-aware parse
  (receipts/r124-r126-egress-comp-envelope-sentinel-quote-parse.md),
  api-version gates (r143/r145), unreachable clause removal (r171)
- dedicated test surfaces: broker facade, egress dispatch/wire,
  auth enforce, apiversion matrix, property/frame_codec, fuzz
  (atom-flood fence D63/R95), r129 session gate, r133 policy CAS,
  r177d/r5 repro tests
```

## 3. errc

```
chore(errc): deps, sdk-coverage compiler, kd_flip, cli gates and workspace repairs

- mix.exs version bump 26.10.16 + dep churn (pyjwt/hypothesis class)
- scripts/sdk_coverage.py: multi-window fail-closed coverage compiler
  (MISSING/UNREGISTERED-GAP refuse); SDK_MATRIX.md rides
  `just sdk-matrix-md`, never hand-patched
- scripts/kd_flip.py multi-window covers-map (witness: receipts/r121-kd-flip-dry.md,
  9 KD ids / 11 files; FLIP-ELIGIBLE 0 confirmed in _LANES.md W12)
- scripts/naming_sweep.sh zero-violation pass (receipts/r20-naming-sweep-zero.md)
- scripts/stage_atomic_commits.sh: egress-test classify to shims,
  dry-run side-effect gate, CHANGELOG classify (receipted in _LANES.md W13-late)
- smalt-cli: gates.py/test_gates.py, conftest proc guard, KD-19/KD-77
  honest SKIP banners (test_servicebus.py:45, test_eventhub.py:69/:91),
  w3 session-ops port-fix markers (receipts/r120-w3-session-ops-port-fix.md)
- workspace: arm-client/credential/eh-stream/resource-queries/sb-telemetry
  repairs, session-ledger (eslint 0 errors + e2e-court PASS=42, receipts/r27-session-ledger-attempt-entry.md),
  verb-gate 8/8 (receipts/r39-verb-gate-8-cases.md), bench pages + topo-worker, e2e-court
```

## 4. planning

```
docs(planning): v26.10.16 window artifacts — lanes, wrap ledger, resolutions, final

- docs/jira/v26.10.16/_LANES.md: full audit/verify/mutate/repair lane
  table W1-W13 incl. W12 DoD sweep and W13 fin-sweep rows
- WRAP_LEDGER.md: KD-70/71 parks, carried parks (dets census
  BOUNDED-WITNESSED, perf variance CLOSED), D127 product gap, residual
  parks carried to fin sweep
- RESOLUTIONS.md seam agreements; FINAL.md (one stale KD-68 line carried
  to fin sweep per W13 row); ash-kudzu-integration.md repaired numbers
  (114→38 types, 3 revops modules — receipts/r03-kd-census-single-sourced.md)
- KNOWN_DIVERGENCES.md window copy, RECEIPTS.md / receipt INDEX /
  SDK_MATRIX / BENCH_RESULTS window artifacts, bench/ jsonl,
  wave-telemetry.jsonl
```

## 5. receipts

```
docs(receipts): v26.10.16 standing-line receipts + v26.10.14 legacy doc refresh

- v26.10.16/receipts/ (128 files, 0 SUSPECT): repair-batch receipts
  W1-W13 with embedded re-run output (see _LANES.md R16 rows for the
  full PASS/PARTIAL_ALIVE/FAIL-WITNESS ledger)
- docs/jira/v26.10.14/ legacy refresh: KNOWN_DIVERGENCES.md KD flips
  (KD-45/53/54/70/71 CLOSED-SIMULATED via kd_flip; KD-76 minted OPEN
  then closed via r200h), RECEIPTS.md, receipts/INDEX.md, bench + fin
  receipts (bench-07/08/12, errc2-benchee, fin32-wrap-final, x7-bench-report)
- generated artifacts regenerated not patched: docs/ERROR_CODES.md
  (`just gen-error-codes`; drift fence fired on R136 literals —
  receipts/r125-error-codes-doc.md), docs/WIRE_PARITY.md GAP sync
  (floor 3 holds, `just gap-sync` exit 0)
- docs: DEV_LOOP timing-receipts table (5 refresh rows), TEST_ISOLATION
  :cross_seat row (receipts/r164-test-isolation-aliases.md), ERROR_SWEEP, JUST_REFERENCE,
  RELEASE_NOTES v26.10.14 + v26.10.16
- test/ stragglers riding the receipts family per classify(): sdk-full
  probes, sdk-python legs + README, error_codes_doc, dets growth census
  (test/store_dets_growth_test.exs), r32/r77 repro tests, tls/kv_tls,
  security/lens5, telemetry, mcp wire
- .ggen_igniter manifest + receipts ledger (generated sync receipts)
```

## 6. gates

```
chore(gates): cosmos etag-cas + ledger-chain gate updates (fail-closed negative fixtures)

- gates/cosmos_etag_cas_gate.py + gates/ledger_chain_gate.py: verdict
  tightening with negative fixtures (receipts/r15-gate-fixtures-verdict-tightening.md,
  receipts/r48 etag CAS 5 fixtures refuse, receipts/r75-r102 ledger
  durability gate exit 0)
- invariant-gates contract upheld: a gate that cannot exit 1 is the
  failure
```

## 7. audit

```
docs(audit): audit-surface findings + census

- docs/audit/ defect findings feeding the R1-R15 repair lanes
- docs/CENSUS.md refreshed (KD census prose re-count 59/18 from table,
  receipts/r101-census-rows.md — source-verified, replay deferred)
```

## 8. repo

```
chore(repo): repo config (CLAUDE.md, gitignore, changelog, pack lock, justfile modules)

- CLAUDE.md: lane/substrate/court convention updates
- .gitignore bench dirs (check-ignore verified, receipts/r80) + lane
  build roots
- CHANGELOG.md [26.10.16] entry (generated-adjacent, classify: repo)
- ggen_igniter.pack.lock + manifest sync receipts
- justfile.d modules: 03-cli-wiring, 11-relay-env, 13-receipt-index,
  14-sdk-matrix (per-module imports; no root justfile edits)
```

## 9. tools

```
chore(tools): substrate/doctor/court/receipt tooling

- scripts/substrate.sh: lock-fd-inheritance law (spawn `9>&-`,
  per-window locking, tree-aware orphan detection — same-checkout-fanout
  addition 4)
- scripts/receipt_index.py multi-window aggregation + standing
  extraction (receipts/r185i-r185k-harness-batch.md,
  receipts/r08-receipt-index-drift-gate.md); regen 288/303/21 witnessed
- scripts/court_x2.sh judge_log compile-abort guard fix
  (receipts/r35-court-x2-judge-log.md FAIL WITNESS closed by
  receipts/r76-judge-log-compile-guard.md)
- scripts/fast_test.sh (per-hash build roots, W13-late smoke green:
  cosmos 123/0, queue_store 52/0), doctor.py, port_sweep.sh
  (receipts/r83-r89-port-sweep.md STILL-HELD map), gen_error_codes.py
  helper window 11→14 (receipts/r178b-error-codes-helper-window.md),
  mutation_court.py (receipts/r36-bench-report-fail-closed.md fail-closed
  A/B), verify_all.sh, dev_env.sh, gen_dev_cert.sh,
  audit_surface_census.sh
```

---

## Execution notes

- Install each message into `write_msgs()` in
  `scripts/stage_atomic_commits.sh` (the script owns msgfile authoring),
  then run without `--dry-run`. Coordinator runs git; lanes never do.
- Re-run `--dry-run` immediately before execution — the partition is
  reclassified from live `git status` and the counts above are
  as-of-2026-10-16.
- Order is fixed: bench → shims → errc → planning → receipts → gates →
  audit → repo → tools. `git commit -F <msgfile>` only, never `-m`.
