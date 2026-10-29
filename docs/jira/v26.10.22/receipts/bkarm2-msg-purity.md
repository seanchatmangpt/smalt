# Receipt: BK-ARM2 — Armstrong-principles audit, lane 2: message-passing purity

Standing: ALIVE. Context: solo.

Lane 2 of the Armstrong fleet: audit the swarm's state model against the
partitioned contract the BK-SWARM court pinned (write on node B → `:error` from
node A — each peer booted a full `Smalt.Store`, no replication anywhere).

## Scope audited (real greps over lib/, 2026-10-22)

- `:global.` — 7 call sites, all `:global.trans/2` locks:
  - `lib/smalt/auth/sts_key.ex:169,238`, `lib/smalt/security/receipt_signer.ex:149`,
    `lib/smalt/trust_profile/trust_profile.ex:779` — every lock key embeds `node()`
    → per-node by construction. Correct: the resource guarded is per-VM key
    material, so cross-node mutual exclusion is neither assumed nor needed.
  - `lib/smalt/tls.ex:320,454` — `{__MODULE__, cert}` key (no node()). This is the
    ONE legitimately cluster-scoped lock: cert generation mutual exclusion. With
    distribution ON, pods serialize cert generation cluster-wide — harmless and
    actually the right semantics; with dist OFF, `:global` degrades to
    node-local — also correct. No shared-state assumption.
- `:persistent_term` — ~30 keys, all module-scoped `{Module, :key}` singletons.
  Every one is node-local by definition. ONE hazard found (fix below).
- ETS heir patterns: `Smalt.Store.Heir` (store.ex:72-88), `apim.ex:150-159`,
  `telemetry.ex:276-289`, `policy.ex:76-82` — all heir to node-local owners
  (`Process.whereis(:init)` / the quiet Heir). Nothing assumes cross-node
  ownership. Store tables are node-local with per-pod DETS replay — the
  partitioned contract, implemented literally.
- Mnesia: ABSENT — `grep -rni mnesia lib/` → zero hits. Confirmed.
- Cross-node reads: no `:erpc`/`:rpc` in lib/ (distribution lives only in
  `lib/smalt/cluster.ex` DNS poller + tests). `whereis` is never used with any
  cross-node expectation.

## Finding + fix (BK-ARM2-F1, fail-closed)

`Smalt.Auth.StsKey.resolve_rs256_jwk/0` dev fallback ran
`JOSE.JWK.generate_key({:rsa, 4096})` once per VM into `:persistent_term` — on a
multi-pod mesh every pod mints a DIFFERENT RSA key. A client that authenticates
against pod A (getting pod A's token) then hits pod B over headless-DNS
round-robin and takes a 401. That is a silent cross-node state assumption — the
exact class this lane hunts.

Fix: fail-closed typed `ArgumentError` when `config :smalt, :cluster,
enabled: true` and no `:sts_signing_pem` is configured. `lib/smalt/auth/sts_key.ex`
(`cluster_enabled?/0` + gate in `resolve_rs256_jwk/0`).

Court: `test/internal/sts_key_cluster_purity_test.exs` — asserts the typed raise
with cluster enabled / pem absent (cache save/erase/restore in on_exit). Real
collaborators, no doubles.

## Client-visible semantics (typed)

Any pod serves any call; state is per-pod. The b4/kd86 per-entity model is
state-per-entity INSIDE one pod's Store; entity placement does NOT migrate —
a write through pod A is invisible to pod B (witnessed by swarm court legs (c)
and k3), and after a pod restart state returns only from that pod's local DETS
journal replay (`Smalt.Store.Boot` sealed-journal replay LAST in store.ex:17).
Clients must pin to the pod that holds the entity (Sticky-session by pod DNS
name, not the headless round-robin name) for read-after-write. This is now also
enforced for identity: tokens are pod-pinned unless `:sts_signing_pem` is set.

## Armstrong's one-sentence state model

> Each pod is a whole emulator: every byte of state — Store partitions, STS
> signing keys, AMQP connections — lives and dies with its node, pods share
> nothing, so any pod serves any call while cross-pod state is invisible by
> contract, not by bug.

One sentence; no paragraph needed. The design does not smell.

## Evidence

Embedded command output:

```text
$ MIX_BUILD_ROOT=_build-lane2 mix test test/internal/sts_key_cluster_purity_test.exs
Finished in 0.02 seconds (0.00s async, 0.02s sync)
Result: 1 passed

$ MIX_BUILD_ROOT=_build-lane2 mix test test/apim_policy_test.exs   # adjacent STS surface
Result: 4 passed

$ MIX_BUILD_ROOT=_build-lane2 mix compile   # clean (lane 2 build root)
Generated smalt app
```

Compile-freeze disclosure: sibling lane's `lib/smalt/powl2/executor.ex` was
transiently non-compiling mid-refactor during this lane's verification window
(mismatched-delimiter error at 506:5); it settled green on its owner's next save
without any ARM2 intervention. `git diff` of that file was read-only
diagnosis, no edit by this lane.

Landing: fix + test landed via coordinator tick checkpoint fcc212cd (snapshot
disclosed in the commit message: "EXPL12-W wire.py handshake + sts_key.ex");
this commit adds the receipt only.

Falsifier: a multi-pod boot with cluster enabled and no `:sts_signing_pem`
must refuse boot/keygen typed (`:cluster is enabled` ArgumentError) — a run
that silently generates per-pod RSA keys with cluster ON reopens this finding.
