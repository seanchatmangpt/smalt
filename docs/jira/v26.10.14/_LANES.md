# v26.10.14 Work Orders — Lane Partition

Release: v26.10.14 · Base: HEAD db2fe05 + uncommitted working tree (117 modified files,
per-lane hardening landed but uncommitted — several orders' first task is to commit their
lane's pending work). Generated 2026-10-15 by a 20-explore + 20-plan fan-out over one
canonical checkout; every claim verified against source at authoring time.

## Work orders

| # | Doc | Lane | Headline | Priority |
|---|---|---|---|---|
| 01 | [01-test-isolation.md](01-test-isolation.md) | test-isolation | canonical_projection restore fix, `ensure_store_up/0`, ~20 heal-site sweep, stop_shared_tree Supervisor wait | **P0** (flake root cause) |
| 02 | [02-store-lifecycle.md](02-store-lifecycle.md) | store | lens7 try/after restore-before-exit, 27-table sweep, kill-restart law in TEST_ISOLATION | P0 |
| 03 | [03-telemetry.md](03-telemetry.md) | telemetry | dump/0 cross-window summing, dead handle_call, total test filter, honest @doc | P1 |
| 04 | [04-event-hubs.md](04-event-hubs.md) | event-hubs | HIGH: EH wire delivery dead code (:1077); renew session sync; session_release serialization | **P0** (product defect) |
| 05 | [05-arm-lro.md](05-arm-lro.md) | arm-lro | DECISION GATE: land LRO sweeper + `:lro_retention`, or typed-OPEN disclosure | P1 |
| 06 | [06-blob.md](06-blob.md) | blob | xml_escape delegation, maxresults alignment, XML envelope + x-ms-error-code (gate), 3 UNSUPPORTED docs | P1 |
| 07 | [07-cosmos.md](07-cosmos.md) | cosmos | list_docs gate wrap, nil-prefix normalization, restart poll, lens3bak delete, SQL whitelist honesty gate | P1 |
| 08 | [08-servicebus-census.md](08-servicebus-census.md) | servicebus | lockDuration pass-through, receive-by-sequence, DLQ properties; census 8→11; 2 UNSUPPORTED | P1 |
| 09 | [09-auth-trust-profile.md](09-auth-trust-profile.md) | auth | hostile key_id crash fix, @type widening, 2^53-1 boundary reconciliation | P1 |
| 10 | [10-mcp.md](10-mcp.md) | mcp | commit lens-7 pending work, setup heal adoption, partition_key INVALID_PARAMS | P1 |
| 11 | [11-publish-blockers.md](11-publish-blockers.md) | publish | delete .ggen from lib/, relocate receipt chain, unconditional key rotation, tar-grep == 0 | **P0** (sole publish blocker; coordinator-gated timing) |
| 12 | [12-gate-closure.md](12-gate-closure.md) | gate | court += mutation-court census invariant-gates naming-sweep; census SKIP-on-3 | P1 |
| 13 | [13-gap-register.md](13-gap-register.md) | gap-register | 2 vacuous-tag deletions, 4 receipt-gated closures, tokenization sweep (C3/C4/C7), honesty paragraph | P1 |
| 14 | [14-docs-drift.md](14-docs-drift.md) | docs | release.txt restamp, sweep-doc cites, /Users/sac scrub/gate, gen-error-codes target, erl_crash.dump | P2 |
| 15 | [15-runtime-contracts-docs.md](15-runtime-contracts-docs.md) | contracts | moduledoc 3→6, pack doc table + 28/0 witness, filetime epoch constant | P2 |
| 16 | [16-ocel-revops.md](16-ocel-revops.md) | ocel | receipt fixture reconciliation, typo, REGENERATION-CLOBBERS fences, release notes | P2 |
| 17 | [17-semantic-epoch.md](17-semantic-epoch.md) | epoch | stale digest doc re-cite (recompute at landing), TEST_ISOLATION inventory, assumption comment | P2 |
| 18 | [18-mutation-courts.md](18-mutation-courts.md) | courts | wire-tier malformed sweep (all admitted types), live engine-kill 503 court, probe stamps | P1 |
| 19 | [19-egress-security.md](19-egress-security.md) | egress | SKR blob-header leak, :dcr_created on ingest, ResourceGraph typed 400, token cap, elem/2 guard, CORS gate | P1 |
| 20 | [20-arm-gateway-hygiene.md](20-arm-gateway-hygiene.md) | arm-hygiene | citation refresh + cite-drift fence, create/3 dedupe, If-Match value verification | P2 |

## Shared-file ownership (disjoint seams)

| File | Owner(s) | Split |
|---|---|---|
| `lib/smalt/egress_router.ex` | 06 / 19 | 06: blob route arms + `blob_error` funnel + `blob_error_xml/4`; 19: SKR/KV arms, `get "/keys"` catch-all, CORS plug |
| `justfile` | 12 / 14 | 12: `court` extension, `census`, `invariant-gates`, `naming-sweep`; 14: `gen-error-codes` target only |
| `lib/smalt/arm_gateway/router.ex` | 20 (05 touchable via lro.ex only) | 20: `check_lock_precondition/2` under decision (a); 05 never edits router.ex (new sweeper file + application.ex child) |
| `lib/smalt/application.ex` | 05 | one additive sweeper child; other lanes disclose, never edit |
| `test/pplan_test.exs` | 02 | 01 delivers `ensure_store_up/0` only; 02 applies it |
| `test/lro_test.exs` | 05 (fences 10-22) / 20 (optional 2.4 clarity) | 05 first; 20 only if file still open after |
| `docs/TEST_ISOLATION.md` | 01 §2 helper doc / 02 §4 kill-restart law / 13 §3 tag table / 17 :62,:78 inventory | disjoint sections |
| `docs/WIRE_PARITY.md` | 13 (register format) / 06+07 (their row content, on receipts) | 13 owns format; 06/07 propose row edits via receipts |
| `docs/PUBLISH_CHECK.md` | 11 (verdict + blocker rows) / 14 (gate section steps) | 11 owns the signing.key rows + verdict; 14 owns the regen step |
| `docs/compliance/C1_ARM_REST.md` | 05 (GAP rows + work-order block) / 13 (register format) | 05 flips rows on landing; 13 owns token grammar |
| `docs/RELEASE_NOTES_v26.10.14.md` | 05 (feature/disclosure line) / 13 (honesty paragraph) / 16 (RevOps bullet) | disjoint lines; 13 reconciles final text last |
| `test/test_helper.exs` | 01 (Lifecycle helper + stop_shared_tree) / 13 (vacuous-tag exclusions :16-22) | disjoint regions |

## Dependency order

```
01 ──→ 02, 10 (ensure_store_up/0 seam)
05, 06, 07, 08 ──→ 13 (receipt-gated register flips)
11 (coordinator-gated: rotation timing)
12, 14 independent (justfile split per table)
03, 04, 09, 15, 16, 17, 18, 19, 20 independent
13 last among doc lanes (final register + release-notes honesty text)
```

## Session state at generation time (already fixed, do not regress)

- `test/chaos/port_collision_test.exs` http_get calls carry `?api-version=2021-04-01`.
- `lib/smalt/trust_profile/trust_profile.ex` `do_sign` else-clause maps `{:malformed_envelope, :bad_epochs}` (lane 09 preserves verbatim).
- `test/semantic_epoch_test.exs` digest-drift test re-cut to derivation-correctness (lane 17 keeps).
- `docs/ERROR_CODES.md` regenerated (69 rows, `--check` exit 0).
- Doctor exit 0; compile warnings-clean; `mix smalt.gen` unchanged-proposal exit 0.
