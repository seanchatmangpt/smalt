# BK-CLV — cluster.ex BK-1SAFE/BK-ARM2 mid-lane break verification

Standing: ALIVE · Context: solo · Lane: BK-CLV · Date: 2026-10-22

## Question

BK-ARM2's receipt (docs/jira/v26.10.22/receipts/bkarm2-msg-purity.md) disclosed that
`lib/smalt/cluster.ex` was mid-lane broken during BK-1SAFE's window and "settled by its
owner". Verify no half-applied edit remains.

## (1) Working tree vs HEAD

`git diff HEAD -- lib/smalt/cluster.ex` → **empty** (0 hunks). `git status --porcelain`
on the file → clean. No restore was needed (BK-CLV performed no restore; the owner's
settle left the file byte-identical to HEAD).

Last commit touching the file: `ca639494` (tick checkpoint, in-flight snapshots). Recent
history (window ca639494 ← 05ff07b2 ← 093b5711 "RS256 identity ... DNS cluster"): 234
changed lines across the last 3 commits, consistent with the landed error-kernel split
(BK-ARM6) and DNS-poll join — no fragmentary hunk shape, no dangling `end`, no orphaned
clauses. BK-ARM2's disclosure names only the DNS poller + a `whereis` purity finding
(fixed in `lib/smalt/auth/sts_key.ex`, not cluster.ex).

## (2) Compile + courts (fresh, MIX_BUILD_ROOT=_build-bkclv)

- `mix compile` → exit 0 ("Generated smalt app"; pre-existing plug/router warnings only).
- `mix test test/cluster/cluster_test.exs test/internal/sts_key_cluster_purity_test.exs`
  → **6 passed** (0 failures; DNS-poll join tests included — production-intended per
  BK-TOPO).
- Tagged courts, included explicitly:
  `mix test --include peer_two_node_court --include swarm_court test/cluster/cluster_test.exs`
  → **5 passed** (peer two-node + swarm courts through real distributed runners).

## (3) Restore

Not required — nothing to restore.

## (4) Typed finding

**ALIVE / CLEAN**: `lib/smalt/cluster.ex` at HEAD carries no half-applied BK-1SAFE/BK-ARM2
residue; compile clean, 11/11 cluster courts green. The disclosed mid-lane break was fully
settled by its owner; no coordinator action needed. No divergence row warranted.
