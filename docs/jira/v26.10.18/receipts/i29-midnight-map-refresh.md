# i29 — Sovereign Midnight coverage-map refresh (SOVEREIGN_MIDNIGHT.md)

Standing: PASS — map refreshed against landed tree; 18/18 tests green; G6 flipped
COVERED with in-tree evidence; G1-G4 verified still MISSING by grep.

Subject: /Users/sac/smalt @ main (working tree; docs-only edits this task).

## Command output (verbatim)

    MIX_BUILD_ROOT=_build-ft-mapref scripts/fast_test.sh \
      test/azsim/sovereign_midnight/sovereign_midnight_test.exs
    ...
    Finished in 0.7 seconds (0.00s async, 0.7s sync)
    18 tests, 0 failures
    [22:40:17] wall: 219s (build root: _build-ft-3c749b8c)

`:sovereign_gap` tag: 0 occurrences in
test/azsim/sovereign_midnight/sovereign_midnight_test.exs — all 18 bodies run
untagged; the tag is retired (matches i29-sovereign-gap-triage.md).

## G-register verification evidence (grep, this session)

- G6 (ARG route family) — LANDED:
  - lib/smalt/egress_router.ex:1311
    `post "/providers/Microsoft.ResourceGraph/resources" do`
  - lib/smalt/data_plane/resource_graph.ex:1,10 `Smalt.DataPlane.ResourceGraph`,
    route binding `POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01 -> query/3`
  - lib/smalt/runtime_contracts/resource_graph_query.ex (contract + generated projection)
  - test 5.3 passes over the live route (sovereign_midnight_test.exs:482).
  Note: parent cited receipts/i29-arg-route-family.md — that file does NOT exist
  on disk (ls receipts/ | grep i29: no such name). Flip here is gated on the
  in-tree code evidence above + i29-sovereign-gap-triage.md instead; flag for
  the coordinator to land or rename that receipt before wrap (docs-dod-check
  would fail on a doc citing the missing path — this doc deliberately does not
  cite it).
- G1 (Queue Storage data plane) — still MISSING:
  - `grep -rn -i "popreceipt\|visibilitytimeout\|queue storage" lib/smalt` → 0 hits.
  - lib/smalt/messaging/amqp/queue_store.ex is the AMQP/SB lock-token store, not
    the Azure Queue Storage REST surface.
- G2 (X-ARR-ClientCert) — still MISSING:
  - `grep -rn "X-ARR\|x-arr" lib/smalt` → 0 hits.
- G3 (Event Grid DLQ spillover) — still MISSING:
  - `grep -rn -i "dlq\|dead.letter\|blob" lib/smalt/messaging/event_grid.ex` → 0 hits.
- G4 (split-brain failover) — still MISSING:
  - `grep -rn -i "split.brain\|failover" lib/smalt` → 0 hits.

## Doc deltas (azsim-burn/SOVEREIGN_MIDNIGHT.md)

- Refresh header line added (18 untagged, tag retired).
- Phase rows updated: 1 Identity (1-bit-flip exercised by test 1.3; expiry race
  still MISSING), 2.2 (test 2.2 evidence), 2.3 (test 2.3 evidence), 3.1
  (typed :lock_lost landed, queue_store.ex:334-352), 3.2 (test 3.2 evidence),
  5 ARG → COVERED (egress_router.ex:1311).
- G5 narrowed to injector-only residuals; G6 CLOSED with residual AZB-20 items
  noted as tracked outside this register. No new GAP tokens minted.

Context: solo. Machine report: n/a (docs-only; single private build root
_build-ft-mapref/-3c749b8c left on disk for coordinator lane-clean).
