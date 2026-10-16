# WO v26.10.15 / 23 — Substrate proxy: the cheaper 20% of WO-01, no launchd

- **Repo:** /Users/sac/smalt (one checkout, no-worktree law unchanged)
- **Supersedes-for-now:** WO-01 (`01-substrate-daemon.md`) — same namespacing
  contract, none of the daemon lifecycle machinery.
- **Grounded in:** `docs/jira/v26.10.14/receipts/dod-01-substrate-lock.md`
  (orphaned flock pid 47479 ppid 1 + leaked beam 48109; two live lanes queued
  behind it, one lane waited ~22 min for `just substrate-up`) and
  `receipts/ws-09-dataplane.md` (lane booted its own substrate under
  `flock -x /tmp/smalt-substrate.lock` on canonical ports — every lane pays
  the lock + port tax to run 11 probe steps).

## 1. Problem

WO-01's full answer is a launchd-managed, version-pinned daemon. That earns
its complexity only after logical isolation proves out. The witnessed pain is
not "no daemon"; it is (dod-01) the lock serialization and its orphan class,
and (fin-11) port-allocator contention. Both come from **physical** isolation
(one BEAM + 4-6 ports per lane, serialized by a global flock). LOGICAL
isolation kills both without any process supervision:

- **Deletes the port allocator and the lock now.** One BEAM, one well-known
  port, started per window by an existing harness — not launchd, not
  `KeepAlive`, not tree-sha pinning, not restart-on-landing.
- Dod-01's entire orphan-detection apparatus (`tree_listening`,
  `orphan_holders`, `lock_holders`) and `substrate.sh`'s flock/spawn/verify
  sequence go away: there is no harness-spawned child, so there is nothing to
  orphan.

## 2. Move

One BEAM GenServer (`Smalt.SubstrateProxy`, new module) answering on **one
well-known port** (e.g. 9443, plus its AMQP/EH twins 5672/5673 — same block
substrate.sh already owns; bound 127.0.0.1 only), that **multiplexes lane
connections to logically namespaced resources**:

- **Contract:** `lane` is `[a-z0-9]{1,8}`; `prefix = "s" <> lane <> "-"`.
  Lane code addresses resources as `prefix <> name` on every stateful surface
  (Store keys, SB queue names, EH hub names, Cosmos db/container, blob
  containers). Identical to WO-01 §3 — deliberately; WO-01 "grows out of
  this" without contract churn.
- **Reuses `Smalt.Store.list_prefix/2` composition** (`lib/smalt/store.ex:134`,
  already used this way by `lib/smalt/arm_gateway/router.ex:501,759,1309`):
  per-lane namespaces are just prefixed key scans; a lane can never observe
  another lane's keys because every read is a `list_prefix(table, prefix <> ...)` scan and every write
  stamps the prefix. Add a thin `Smalt.Store.namespace(prefix)` view (WO-01's
  same file) so lane code never hand-concatenates.
- **Auth mode:** one enforce-mode proxy only (this WO). Anonymous-mode lanes
  keep private boots; fin-05's mode-drift class is not re-solved here — WO-01
  §4 solves it topologically later.

## 3. What is explicitly NOT in this WO (deferred to WO-01)

- No launchd, no plists, no `substrated_install.sh`, no `KeepAlive`.
- No version-pinning / tree_sha identity / restart-on-landing contract.
- No anonymous listener block, no per-request auth-mode question at all.
- No `_build-substrate` warm build root, no read-only-lane law.
- WO-01 is not cancelled: once the proxy survives a full wave (receipts show
  zero contention events at 20-lane fan-out), WO-01's launchd+identity layer
  is grown onto it (the GenServer becomes the daemon; the prefix contract is
  already the same contract).

## §3.5 Lock and port-allocator deletion

- `scripts/substrate.sh` (`flock -w 300` + orphan sweeps) → shim to
  "verify proxy listeners, else boot proxy" — the flock and both orphan
  sweeps are **deleted**, not migrated.
- `justfile.d/01-substrate-lock.just` recipes repoint at the proxy boot.
- `bench_boot`'s private-port algebra stays (WO-01 §3 rule 3: bench lanes
  measure boot-to-accept wall; a shared proxy makes that meaningless) — but
  SDK lanes stop allocating port blocks.

## 4. Falsifier

The claim "one GenServer + per-lane prefixes removes port/lock contention at
lane fan-out, without a daemon" is **false** if:

- **F1:** 20 lanes (each: one SDK smoke slice + one Store churn slice, all
  prefixed) run concurrently against the proxy and ANY of: a port-collision
  event in `lsof` sampling (5s interval), any flock wait on
  `/tmp/smalt-substrate.lock`, or a cross-lane prefix read (lane B observes
  lane A's data under its own prefix scan) occurs.
- **F2:** proxy-mode suite wall for the slice is not materially better than
  the witnessed contention-regime p95 (dod-01's 22-min `substrate-up` queue;
  ws-09's per-lane boot tax) — the proxy must beat the contention regime, not
  match it.
- **F3:** a Store crash under the proxy kills lane isolation for any lane
  other than the crashing lane's prefix scans (proxy owns supervision; a
  lane-scoped crash must not host-wide-outage — if it does, this WO's
  "no daemon yet" premise is wrong and WO-01 is pulled earlier).

## 5. Acceptance

1. `GET /metadata/endpoints` 200 on the single well-known block; no flock on
   `/tmp/smalt-substrate.lock` exists at any point (file may exist, no
   process waits on it).
2. Prefix isolation witness: two lanes, same resource names, lane B never
   sees lane A's data; `list_prefix(table, "sb1-")` never returns unprefixed
   or foreign-prefixed keys.
3. 20-lane falsifier F1/F2 executed, zero contention events, receipt recorded
   at `docs/jira/v26.10.15/receipts/23-substrate-proxy.md`; `du -sh _build-*`
   shows no new per-lane build roots for proxy consumers.
4. `substrate.sh`'s orphan-detection code paths are deleted (grep for
   `lock_holders|orphan_holders` in scripts/ returns nothing).
5. F3 crash witness: kill the Store under the proxy; supervision restart is
   proxy-scoped; a lane slice on another prefix completes during the restart.

## 6. Files owned

- `lib/smalt/substrate_proxy.ex` (new, GenServer, listener block owner)
- `lib/smalt/store/namespace.ex` (new, small — `Smalt.Store.namespace/1`)
- `lib/smalt/store.ex` (compose `namespace/1` with `list_prefix/2`)
- `scripts/substrate.sh` (shim; delete flock + orphan apparatus)
- `justfile.d/01-substrate-lock.just` (repoint)
- `test/chaos/crash_isolation_test.exs` (F3 witness)
- `docs/DEV_LOOP.md` (substrate section note)
- Receipt `docs/jira/v26.10.15/receipts/23-substrate-proxy.md` with F1-F3
