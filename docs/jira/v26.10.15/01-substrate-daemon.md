# WO v26.10.15 / 01 — Node-level shared substrate daemon (LOGICAL isolation replaces per-lane ports+locks)

- **Repo:** /Users/sac/smalt (one checkout, no-worktree law unchanged)
- **Seed:** `scripts/substrate.sh` (per-window flock manager, DoD-1), `scripts/bench/lib.sh` (`bench_boot` per-lane private-port pattern), `scripts/bench.py::spawn_substrate`
- **Witnessed failures designed against** (all in `docs/jira/v26.10.14/receipts/`):
  1. **4× lock fd-inheritance leaks**, worst a **27-minute starvation** (`dod-01-substrate-lock.md`: orphaned `flock` pid 47479, ppid 1, 22 min at witness + leaked beam 48109 holding the lock; two live lanes queued behind it).
  2. **Port-allocator contention** — lanes queued ~20 min on the shared flock; `fin-11-census-ports.md` shows the structurally different failure too (front door pinned 4 ports, left 2 unpinned, boot aborted on 9444/9545 collision).
  3. **Per-lane `MIX_BUILD_ROOT` = 33.7 GB** — 37 orphaned `_build-*` dirs; each lane recompiles deps+app from scratch (50-60s cold per target).
  4. **Auth-mode drift between boots** — `fin-05-auth-mode-pin.md`: a concurrent lane's enforce-mode VM on shared 9443/8443 poisoned tokenless SDK probes; fixed per-harness by pinning `:anonymous` in every boot eval — a per-boot property that should be a per-listener property.

## 1. Architectural move

Replace **PHYSICAL isolation** (each lane boots its own BEAM on its own 4-6 ports, serialized by a global flock) with **one long-lived substrate daemon per host** and **LOGICAL isolation**: lanes connect to a well-known endpoint and are separated by **per-lane name prefixes** on every stateful resource — Store key namespaces, queue names, db/container names. The prefix discipline is already proven by the SDK lanes' unique-name hygiene (`test/sdk-smoke/`) and by `scripts/bench/lib.sh`'s deterministic `39000 + lane*10` algebra — we keep the algebra, change what it names (resources, not ports).

| Witnessed failure | Killed how |
|---|---|
| Lock fd-inheritance leak (27 min starvation) | Structurally: no flock, no harness-spawned child. launchd owns the process (`KeepAlive`); nothing inherits anything. `substrate.sh`'s entire orphan-detection apparatus (`tree_listening`, `orphan_holders`, `lock_holders`) becomes dead weight to delete. |
| Port-allocator contention / 20-min queues | Exactly one port block per auth mode on the host. `bench_boot`'s pre-flight `lsof` collision check and `SMALT_TEST_*_PORT` pinning become unnecessary for daemon consumers. |
| 33.7 GB / 37 orphaned `_build-*` | One warm build root (`_build-substrate`) owned by the daemon. Consuming lanes run **read-only tests** against the running tree — no `MIX_BUILD_ROOT` per lane. |
| Auth-mode drift (fin-05) | Mode becomes a **listener property**, not a boot-env property. Lanes bind to the mode's endpoint and cannot inherit the other mode. |

## 2. Daemon lifecycle (launchd, version-pinned to checkout HEAD)

### 2.1 Process model

Two BEAM instances under one launchd agent (darwin host), one per auth mode (§4 for why two, not one):

- `dev.smalt.substrate.enforce` → 9443 (ARM), 9444 (arm_tls), 5672 (amqp), 5673 (event_hubs), 8443 egress, 9545 MCP — the legacy-compatible block from `substrate.sh PORTS`.
- `dev.smalt.substrate.anon` → parallel block **9453 / 9454 / 5692 / 5693**, egress 8453, MCP 9555.

Both plists generated from one template by `scripts/substrated_install.sh`, `KeepAlive=true`, `RunAtLoad=true`, logs `/tmp/smalt-substrate-state/{enforce,anon}.log`. All ports 127.0.0.1 only. A **single global flock on `/tmp/smalt-substrate-daemon.lock` guards install/restart only** (held by the short-lived install script, child spawned `9>&-` — the per-window discipline preserved for the restart window only).

### 2.2 Tree tracking — how the daemon knows which tree it serves

The daemon boots with a **pinned identity** written at spawn and echoed on a health endpoint:

```elixir
Application.put_env(:smalt, :substrate_identity, %{
  git_sha:     "<rev-parse HEAD at spawn>",
  tree_sha:    "<git write-tree with dirty-file hashes>",   # dirty-aware: MID-EDIT trees must not be served as if clean
  booted_at:   iso8601,
  auth_mode:   :enforce | :anonymous
})
```

`GET /metadata/endpoints` stays the liveness witness (no `/health` route exists — do not invent one); add `/substrate/identity` returning the identity map as JSON.

- Every lane client (`test/support/substrate_client.exs`, new) **fails fast** if `daemon.git_sha != git rev-parse HEAD` unless `SMALT_SUBSTRATE_ALLOW_STALE=1` (docs-only lanes). Dirty `tree_sha` mismatch → also fail-fast (a lane that lands edits and reruns against a daemon serving the pre-landing tree produces false greens). Anti-drift law: **a lane never silently tests against a stale tree.**
- **Restart-on-landing contract:** `just substrate-sync` compares daemon identity vs HEAD + fresh `write-tree`; on mismatch it restarts the affected mode's daemon (flock-guarded, `9>&-`). Wired as the **last step of the landing recipe** (`justfile.d/09-verify-all.just` chain) and into `scripts/release.sh` post-landing. Restart is warm (`_build-substrate` pinned to the checkout) — seconds, not the 50-60s cold compile.

### 2.3 Health / status / down

- `just substrate-status` (repurpose existing recipe): probes both mode blocks, prints identity, plus `launchctl print gui/$UID/dev.smalt.substrate.*` one-liners.
- `just substrate-down` → `launchctl bootout` both labels (flock-guarded). **Chaos courts never touch the daemon** — see §5.
- `scripts/doctor.py` gains a substrate-identity check (daemon sha vs HEAD).

## 3. Namespacing contract (LOGICAL isolation)

```
<lane> ::= [a-z0-9]{1,8}                        # e.g. b1, lane09, sdk, c4
prefix ::= "s" <lane> "-"                        # e.g. "sb1-", "slane09-"
```

| Surface | Law | Example |
|---|---|---|
| Store tables | per-lane key namespace: lane code uses keys `prefix <> key` via a new `Smalt.Store.namespace(prefix)` view; composes with existing `list_prefix/2` / `prefix_keys/2` | `sb1-sub-1` |
| Service Bus | queue names `prefix <> name` | `sb1-orders` |
| Event Hubs | hub names prefixed | `sb1-telemetry` |
| Cosmos | db + container names prefixed | `sb1-db` / `sb1-main` |
| Blob | container names prefixed (3-63 lowercase grammar satisfied by prefix grammar) | `sb1-cont` |

Rules:
1. Prefixes mandatory for daemon consumers; the daemon refuses unprefixed creates where it can, and the client-side namespace view enforces at the Store layer.
2. Prefixes make lane state **reclaimable**: `just substrate-sweep sb1` deletes every resource under a prefix.
3. **Bench lanes out of scope for migration** (they measure boot-to-accept wall; a shared daemon makes that quantity meaningless) — `bench_boot` keeps private ports.
4. `config/test.exs` random-ephemeral fallback (fin-11) stays for private-boot opt-outs only.

## 4. Auth-mode handling — decision: distinct listener blocks per mode, on one host

The daemon serves BOTH modes as two BEAM instances on distinct port blocks. Per-request mode header is **rejected**.

**Justification:** mode is read from application env throughout the enforcement layer (fin-05's fix was `Application.put_env(:smalt, :auth_mode, ...)` in boot evals across three harnesses). A per-request `X-Smalt-Auth-Mode` header would (a) leak a non-Azure header into wire-parity surfaces, breaking courts asserting exact header sets; (b) let one lane's request flip the interpretation of another lane's 401-vs-400 assertions (fin-05's exact failure); (c) require touching `lib/` enforcement paths that are currently stable. Distinct listeners make mode **topological**: a lane on 9453 cannot be affected by an enforce-mode VM — fin-05's failure made structurally impossible. Cost is one extra BEAM (~1 GB RSS class) — cheap against a 27-minute starvation.

## 5. Opt-out to private substrate — the fail-closed courts must not be broken

Suites that REQUIRE their own tree **opt out and are exempted from the daemon law**:

- `test/chaos/port_collision_test.exs` — asserts a second bind fails closed while the first keeps serving. Against a shared daemon this is meaningless and would kill a fleet listener.
- `test/chaos/crash_isolation_test.exs` — kills the Store GenServer and asserts supervision restart **in that tree**. Killing the daemon's Store is a host-wide outage.
- Crash courts / mutation courts (`scripts/mutation_court.py`, `scripts/court_x2.sh`) — must observe code in a tree they own.

Mechanism: suites set `@moduletag :substrate_private` (excluded by default from daemon-mode runs); the helper boots a private substrate via the existing private-port spawn. **Guard, fail-closed:** at suite start, assert the private boot actually owns its ports (`lsof` pre-flight) — a private-tagged suite resolving to the shared daemon endpoint fails immediately with typed `:substrate_leak`, so the daemon can never silently absorb a fail-closed court.

## 6. Migration from substrate.sh

1. **Land daemon + client + opt-out (this WO).** `substrate.sh` unchanged; both paths live.
2. **Flip the default** (mid-release): `just substrate-up` becomes "verify daemon identity vs HEAD; restart if stale"; old flock-spawn moves to `scripts/substrate_legacy.sh`, kept **one release** (bench lanes and courts keep private boots anyway).
3. **Delete** `substrate_legacy.sh` + the orphan-detection apparatus at release+1; DEV_LOOP's starvation/port-contention ledger rows re-typed against the daemon.

Ordering: namespacing (§3) before the default flip; the SDK lanes' unique-name discipline becomes *mandatory* prefix law at flip time.

## 7. Falsifier

The claim "one daemon + prefixes removes port/lock contention at lane fan-out" is **false** if:

- **F1:** 20 lanes run a concurrent suite slice (each: one SDK smoke slice + one Store churn slice, prefixed) against the daemon, and **any** of: a port-collision event in `lsof` sampling (5s interval, both blocks), a lock wait on `/tmp/smalt-substrate-daemon.lock` longer than the restart window, or a cross-lane prefix read — occurs.
- **F2:** daemon-mode suite wall for the slice is not materially better than the witnessed contention-regime p95 (10.8s boot class, DEV_LOOP budget) — the daemon must beat the contention p95, not match it.
- **F3:** a landing mid-run (tree_sha change) does NOT fail-fast lane clients (stale-tree serving would be a false-green generator — the worst class in this repo).

## 8. Acceptance criteria

1. `launchctl print gui/$UID/dev.smalt.substrate.enforce` / `.anon` → PROGRAM RUNNING; `/metadata/endpoints` 200 on both blocks.
2. `/substrate/identity` → JSON with `git_sha == $(git rev-parse HEAD)`, `booted_at`, `auth_mode`.
3. Fail-fast witness: land a throwaway commit, do NOT restart, run a lane slice → typed stale-tree error; `SMALT_SUBSTRATE_ALLOW_STALE=1` → runs; witness mode discrimination (tokenless `/subscriptions` on 9443 → 401, on 9453 → 200).
4. Prefix isolation witness: two lanes, same resource names; lane B never sees lane A's data; `substrate-sweep sb1` removes only `sb1-*`.
5. Chaos courts green on private boots; the `:substrate_leak` guard holds (chaos suite with daemon up must NOT touch 9443/9453).
6. 20-lane falsifier F1/F2 executed, zero contention events, receipt recorded; `du -sh _build-*` shows **no new per-lane build roots**.
7. `substrate-down && substrate-up` round trip ≤ 30s warm (was: up to 300s flock wait + 90s boot).

## 9. Files owned

- `scripts/substrated_install.sh` (new) + generated plists (not committed)
- `scripts/substrate_client.sh` (new) — lane-side identity check + fail-fast library
- `test/support/substrate_client.exs` (new) — Elixir identity check, prefix view wiring, `:substrate_leak` guard
- `justfile.d/16-substrate-daemon.just` (new) — `substrate-sync/status/down/sweep`; edits `justfile.d/01-substrate-lock.just` (repoint `substrate-up`)
- `lib/smalt/substrate_identity.ex` (new, small) + `/substrate/identity` route
- `lib/smalt/store/namespace.ex` (new, small) — `Smalt.Store.namespace/1`
- `test/chaos/{port_collision,crash_isolation}_test.exs`, `scripts/mutation_court.py`, `scripts/court_x2.sh` — `:substrate_private` tags + guard
- `docs/DEV_LOOP.md` — substrate section rewrite
- Landing receipt `docs/jira/v26.10.15/receipts/01-substrate-daemon.md` with F1-F3 evidence
- Deleted at §6 step 3: `scripts/substrate.sh` (or shimmed to `substrate_legacy.sh` first)
