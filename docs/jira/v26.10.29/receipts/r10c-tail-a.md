# R10C — Tail sweep A: kql, management_rpc, queue_store

window: v26.10.29 · lane: L14 (THIRD attempt; two prior rate-limit deaths) ·
ticket: T10 (tail-splits, leg A) ·
status: **ALIVE for the lane subject — 113/121 gate across 22 court files;
8 failures disclosed, none on lane-owned surfaces** (7 share one in-flight
non-owned router signature; 1 is the documented class-(a) env probe timeout).

## Subject and per-file extraction list

Repo /Users/sac/smalt, branch main, HEAD 338caed at lane start. Working tree
only — coordinator owns git transitions; no commits, no git commands by this
lane. On-disk state verified this attempt (find/ls/wc on disk, 2026-10-29
23:1x-23:3x):

| file | state | lines |
|---|---|---|
| `lib/smalt/data_plane/kql.ex` | monolith INTACT — single module `Smalt.DataPlane.KQL`, no `kql/` split dir exists anywhere in lib/ | 1,542 |
| `lib/smalt/messaging/amqp/management_rpc.ex` | facade: `handle/2` + `normalize_op/2` dispatch + alias block; per-family bodies transplanted to siblings | 309 |
| `lib/smalt/messaging/amqp/management_rpc/` (12) | `Shared` (228), `Schedule` (187), `Rules` (133), `MessageSessions` (117), `UpdateDisposition` (150), `ReceiveBySequence` (75), `SessionState` (73), `EventHubsRead` (98), `LockRenew` (57), `LockRenewSession` (32), `Peek` (51), `BatchDelete` (48) | 1,249 |
| `lib/smalt/messaging/amqp/queue_store.ex` | monolith INTACT — single module `Smalt.Amqp.QueueStore`, no `queue_store/` split dir exists anywhere in lib/ | 1,435 |

### Split layout (landed by the prior L14 attempts, verified intact this attempt)

- `lib/smalt/messaging/amqp/management_rpc.ex` (309 lines) keeps the moduledoc
  ("Split layout (tail-splits ticket T10)"), the 12-module alias block, the
  @sb_ops list, `handle/2` dispatch table, `normalize_op/2` (3 clauses +
  normalize_read/2), and the fallback `handle(_request, _context)` clause.
  Zero own business logic.
- 12 siblings under `lib/smalt/messaging/amqp/management_rpc/`, one fenced
  family each, transplanted verbatim from the pre-split monolith:
  `Shared` (228: respond/4, normalize helpers, put-token context plumbing),
  `Schedule` (187: schedule-message + cancel-scheduled-message, KD-118),
  `Rules` (133: add/remove/enumerate-rules, w6m), `MessageSessions` (117:
  get-message-sessions + get-namespace-usage, w6n), `UpdateDisposition` (150),
  `ReceiveBySequence` (75), `SessionState` (73), `EventHubsRead` (98, KD-19),
  `LockRenew` (57), `LockRenewSession` (32), `Peek` (51), `BatchDelete` (48).
- Consumers untouched: `connection.ex` and `listener.ex` keep calling
  `ManagementRpc.handle/2` — wire-visible behavior unchanged.

## Method (third attempt — no restart)

The prior attempt's state was already on disk (12 sibling modules + facade at
mtime 22:30; kql.ex and queue_store.ex monoliths). This attempt continued at
step 1 of the contract: compile, courts, receipt. No lib edits inside lane
ownership this attempt; no test edits; no pattern-kills (every court file in
the discovery union was run to completion, failures reported as observed).

### Disclosed minimal unblock (SLA, not lane-owned — for BOTH lanes' receipts)

`lib/smalt/data_plane/blob_storage.ex` (lane L09 blob split's file, NOT lane
L14 ownership) was compile-broken from 22:57 to ~23:22 (first observed 23:19,
still broken 23:21 — 24 min past the ~10-min compile-freeze SLA; owner lane
actively rewriting: 23:15 rewrite, later 23:32 rewrite). Two-part minimal
unblock applied at ~23:22, disclosed per same-checkout-fanout addition 2:

1. Lines 1130-1133: four `defdelegate` lines carrying `\` → `\\` default-arg
   typos (5 default-arg sites: `policy_state/3`, `set_immutability_policy/5`,
   `delete_immutability_policy/4`, `set_legal_hold/4`) — the compiler reported
   only the first, at 1130:53.
2. Six `worm_blocked?(` call sites (lines 243, 275, 495, 1175, 1316, 1369)
   qualified to `Worm.worm_blocked?/3` — completing the file's own established
   qualification pattern (adjacent sites already call `Worm.worm_message` and
   `Worm.blob_immutability_refuses?`), with the public 3-arg clause on
   `Smalt.DataPlane.Blob.Worm` (worm.ex:424) matching the call shape exactly.
   No semantic decisions: signature-identical.

Both edits are mechanical, semantics-preserving, and were required to compile
the shared tree at all. Post-gate note (23:34): the L09 lane continued surgery
(`blob_storage.ex` 103KB→78KB, new `blob/leases.ex` — transiently
non-compiling in their active window); the gate results below are as-of their
embedded timestamps, before that rewrite. `MIX_BUILD_ROOT=_build-l14`, asdf-pinned
`elixir 1.20.4-otp-29 / erlang 29.1.2` (`.tool-versions`; homebrew 1.19.5
shadows asdf shims on PATH — pinned toolchain forced via PATH prefix).

## Verification ladder (real output embedded)

1. Compile, lane build root (after the disclosed unblock):

```
$ MIX_BUILD_ROOT=_build-l14 MIX_ENV=dev mix compile
Compiling 21 files (.ex)
Compiling 9 files (.ex)
Generated smalt app
EXIT=0
```

15/15 owned beams present in `_build-l14/dev/lib/smalt/ebin/`:
`Smalt.Amqp.ManagementRpc` + 12 `ManagementRpc.*` siblings + `QueueStore` +
`KQL` — 15 beam files, all listed by ls.

2. Court discovery (union of three probes — the contract's lowercase-`kql`
grep misses the six kql-named court files, so the run set is the union):

```
$ grep -rl 'kql\|management_rpc\|QueueStore' test/integration test/internal --include='*.exs'  → 14 files
$ grep -rli 'ManagementRpc\|QueueStore' test --include='*.exs'                                 → +kd128_partition_readout, +sb_topic_fanout (test/ root)
$ find test -iname '*kql*'                                                                    → +6 kql-named files (4 integration, 2 data_plane)
```

3. Gate (ALIVE): 22 court files, three batches, `MIX_BUILD_ROOT=_build-l14 mix test ...`:

```
Batch K (kql engine + route): Result: 41/44 passed / Failed: 3 tests
  kql_bin, kql_join, kql_mv_expand, kql_where_route, data_plane/kql_test, data_plane/kql_sealed_court
Batch M (management/queue integration): Result: 46/50 passed   (47.0s)
  bk87_arm_delete_purge, servicebus_rest_dataplane, amqp_kd131_133_triage,
  ja7_crash_only_court, sb_delivery, store_partition_wire_regression, chaos_injectors
Batch I (internal + sb_topic_fanout): Result: 26/27 passed     (75.0s)
  bk27_kd86_auto_ensure_gate, scvd_concurrency_courts, b4rc_send_gate_court,
  internal_tier_census, kd115_credit_first_delivery, kd134_requester_delivery,
  kd128_partition_readout, vm_zero_growth, sb_topic_fanout
TOTAL: 113/121 passed, 8 failed, EXIT=2
```

4. Failure disposition (cite, don't mask; attribution evidence for each):

- **7 failures, one signature, non-owned surface, in-flight owner**: all 7
  (KqlWhereRouteTest 0/3; Bk87ArmDeletePurgeTest 0/4) are
  `** (Plug.Conn.AlreadySentError) the response was already sent` raised in
  `Smalt.ArmGateway.Plug.Common.send_arm_error/6` at `common.ex:178`, via
  `Smalt.ArmGateway.Router.dispatch/2`. Evidence of non-attribution to L14:
  (i) zero stack frames in `KQL`, `ManagementRpc*`, or `QueueStore`; (ii)
  deterministic solo: where_route 0/3 standalone; bk87 0/4 standalone
  (EXIT=2 each); (both solo runs exited 2 with the same first-error line)
  (iii) the failing surface is being actively rewritten DURING the gate:
  `arm_gateway/plug/common.ex` mtime 23:17, rewritten again 23:32 mid-solo-run;
  `arm_gateway/router.ex` 23:12 — the W1 router-wiring lane's in-flight edits
  (NEXT_WAVE W1: routers being mounted/reordered around maybe_parse_body);
  (iv) the signature hits two unrelated route families (ResourceGraph query
  route + ServiceBus namespace PUT) whose only common element is the shared
  error-send path. Classified: in-flight-tree failure of the router-wiring
  lane's surface. NOT masked: reported verbatim above and in both batches.
- **1 failure, documented class (a) environment probe timeout**: `Kd115CreditFirstDeliveryTest`
  timed out at 60s on `System.cmd(node, [probe])` (probe-node boot under
  multi-lane load). Named test class in the r4 baseline triage
  (docs/jira/v26.10.29/receipts/r4-baseline-triage.md, class (a)
  flake/environment, quote D names this exact module). Also
  NEXT_WAVE W3: "~5 run-to-run delta". Cited, not masked; npm `rhea` IS now
  present (verified on disk), so this run's variant is the 60s boot timeout,
  not the rhea-absent variant.

## Contract-cited pre-existing failures — observed status

The lane contract named "kql join/mvexpand/workspace per r4 triage" as
pre-existing deterministic failures to cite. Observed this attempt: those
courts are GREEN — `kql_join_test.exs` (8 tests), `kql_mv_expand_test.exs`
(10 tests) and the workspace leg inside it all passed inside the 41/44 batch;
the only kql failures are the 3 `KqlWhereRouteTest` router-path tests (shared
in-flight surface, disposition above). The r4 triage's kql naming appears to
predate the current tree state; this receipt reports observed status, per
receipt-cited-counts-are-stale-by-default discipline.

## Standing

**ALIVE** (subject-scoped): compile exit 0 in `_build-l14`; 15/15 owned beams;
113/121 across the complete 22-file court union, with every failure
attributed to a non-owned in-flight surface (7, evidence above) or a
documented environment class (1). Owned-surface behavior evidence: all courts
directly exercising `Smalt.DataPlane.KQL` (engine, bin, join, mv-expand),
`Smalt.Amqp.ManagementRpc` (kd128_partition_readout, amqp_kd131_133_triage,
sb_delivery, servicebus_rest_dataplane, ja7, store_partition, chaos,
scvd_concurrency, b4rc_send_gate, bk27_kd86, kd134, internal_tier_census,
vm_zero_growth, sb_topic_fanout) — every court touching the owned modules
passed. kql_where_route + bk87 fail only through the shared ARM-gateway
error-send path being rewritten by another lane mid-gate.
