# r2_state — State/Isolation Redteam Findings

Run: 2026-10-15T03:58:34Z (canonical run, /tmp/r2-final-run.log).
Subject: smalt substrate @ /Users/sac/smalt (fresh `mix run --no-halt`, MIX_ENV=test,
lro_delay_ms=12000), via `test/redteam/r2_state/run.sh`.
Result: **12 pass / 1 CRITICAL finding** (13 scenarios). S6a failed in every run (5/5).

## Findings summary

| id | scenario | severity | status | summary |
|---|---|---|---|---|
| F1 | S6a | CRITICAL | reproducible 5/5 | Confidential Ledger Merkle chain FORKS under concurrent appends |
| F2 | S3a | KNOWN-GAP (high) | pinned | ARM resources carry no ETag surface; conditional writes unenforceable |
| F3 | S2c | KNOWN-GAP (medium) | pinned | RG DELETE does not cascade; orphaned children remain readable |
| F4 | S5a | KNOWN-GAP (medium) | pinned | `/subscriptions/:sub/operations/:op` ignores subscription scoping |
| F5 | S1 | KNOWN-GAP (medium) | pinned | Subscription ids alias across case (store keys fully downcased) |
| F6 | S2b | pin (medium) | pinned | Second PUT during pending LRO admitted (202, new op), no conflict detection |
| F7 | S5b | pin (medium) | pinned | Op for a deleted resource completes Succeeded (phantom success) |
| F8 | S4 | pin (low) | by-design disclosure | Vault/vault collapse to one record; different-casing PUT overwrites without 409 |

## F1 — CRITICAL: ledger chain forks under 32-writer race (S6a)

- 32 concurrent `POST /app/transactions` with distinct contents: all 201, tx ids
  unique, seqs unique — but the Merkle chain breaks: tx `2.1` carries
  `prev_hash = 0x00…0` (genesis) while `1.1` exists with a real root. Two writers
  raced the read-latest-root -> mint path in
  `lib/smalt/security/confidential_ledger.ex` (the `latest_root/1` read is not in
  the same critical section as the seq counter). The chain is NOT an unbroken
  linear history under concurrency; receipts do not compose into one canonical
  chain. Verified by full recomputation of data_hash/prev_hash/merkle_root from
  the authoritative list endpoint.
- Repro: `sh test/redteam/r2_state/run.sh` (S6a), observed in all 5 runs.
- Companion control: S6b (32 concurrent identical contents) holds: 1x201 / 31x409 —
  the dup-detection counter is atomic; the chain-extend path is not.

## F2 — ARM resources have no conditional-write surface (S3a)

- ARM resource GET issues **no ETag header** and the generic resource PUT ignores
  `If-Match` entirely (handler never reads it; only the azapi `lock` action requires
  If-Match presence, without validating its value). Stale If-Match PUT observed ->
  400 (GraphLaw shape refusal of the probe body, independent of the header);
  unconditional writes always win. No lost update was produced *through the header
  path* because the header is inert — which is the gap: conditional concurrency
  control is absent, so any client relying on If-Match has zero protection.
- Companion control: Cosmos plane is correct — S3b 100/100 stale-etag PUT -> 412,
  zero lost updates.
- Repro: S3a in the suite.

## F3 — RG DELETE does not cascade (S2c)

- DELETE of a resource group with children: RG 404s, children remain readable
  (200). Orphan risk for clients modeling hierarchy. Pinned both children 200,
  cleaned up in-test.

## F4 — Cross-subscription operation read (S5a)

- `GET /subscriptions/<B>/operations/<op-of-A>` -> 202/200 with the full op record
  (`resourceId` still names sub A). Route `/subscriptions/:sub_id/operations/:op_id`
  (`lib/smalt/arm_gateway/router.ex`) calls `LRO.get_op/1` and never checks
  `sub_id`. Mitigated by 12-byte random op ids (unguessable), hence medium.

## F5 — Subscription id case aliasing (S1)

- Resources created under sub `1111…1` are readable via the uppercased
  subscription id — GET returns 200 with the same record. Store keys are the full
  downcased ARM id, so subscription (and resource/RG) ids alias across case.
  Cross-sub reads with correct case are properly isolated (404 + clean lists) —
  the leak is the case alias only.

## F6 — No conflict detection for PUT-during-LRO (S2b)

- Second PUT while the first create-op is InProgress -> 202 with a NEW operation;
  both ops later complete Succeeded. Concurrent creates of one resource are both
  admitted (Azure would 409/412).

## F7 — Phantom-success op for deleted resource (S5b)

- DELETE during a pending create-op: resource immediately 404, the InProgress op
  is not cancelled and completes Succeeded. A poller that trusts op status
  believes a resource exists that never will.

## F8 — Case/whitespace squatting semantics (S4)

- `Vault`/`vault` collapse to ONE record (store keys downcased); the
  different-casing PUT returns 200 overwrite (no 409), record keeps first casing
  in `id`/`name`. Whitespace variant `" vault "` is a separate record (no
  collision with bare name). By-design case-normalization, low severity.

# Per-scenario receipts (canonical run)

- S1 KNOWN-GAP: cross-sub GET 404; cross-sub RG/provider LIST clean; uppercased
  subscription id resolves A's resource -> 200.
- S1b PASS: cross-RG GET 404, sibling-RG type LIST empty.
- S1c PASS: db1/db2 namespaces isolated, same id across dbs distinct; DB1 -> 404.
- S2a PASS: 40 racing PUT/DELETE requests, zero 5xx, all {200,201}, terminal GET
  200, id consistent.
- S2b PINNED: second PUT while op InProgress -> 202 (no conflict detection); first
  op completes Succeeded.
- S2c KNOWN-GAP: RG DELETE does not cascade; children readable (200) while parent
  RG 404.
- S3a KNOWN-GAP: ARM GET ETag header=null; stale If-Match PUT -> 400 (shape
  refusal); final v=1 (no lost update through the inert header path).
- S3b PASS: 100/100 stale-etag Cosmos PUT -> 412; zero lost updates.
- S4 PINNED: Vault/vault one record; different-casing PUT 200 overwrite; " vault "
  separate record, no collision.
- S5a KNOWN-GAP: cross-sub op read -> 202 with sub-A op record.
- S5b PINNED: DELETE during InProgress create-op -> 200, resource 404, op still
  Succeeded.
- S6a CRITICAL: chain break at 2.1 (prev_hash=0x00…0 while 1.1 exists) — chain
  forked under 32-writer race; recomputed end-to-end.
- S6b PASS: 32 same-content concurrent appends -> 1x201 / 31x409.

## Harness notes (r2_state lane)

- Substrate lifecycle owned by `run.sh`: fresh substrate per run on dedicated ports
  39443/39444/38443/35672/35673 (via `SMALT_TEST_*_PORT` env vars — `mix run -e`
  put_env runs after app start and does NOT reconfigure listeners), lro_delay_ms=12s
  (via -e put_env; read lazily; InProgress reachability verified), bearer-token
  bootstrap from the substrate's own STS (works under enforce or anonymous mode).
- Exit code: 1 while F1 reproduces (S6a is the failing test); 12 pass / 1 fail is
  the expected terminal state until F1 is fixed.
- F1–F8 are pre-existing substrate behavior, not session-introduced. Harness-only
  defects found during bring-up (port collisions with other lanes' substrates,
  `mix run -e` eval-ordering, mix wrapper vs beam process lifecycle) were fixed
  forward in run.sh.
