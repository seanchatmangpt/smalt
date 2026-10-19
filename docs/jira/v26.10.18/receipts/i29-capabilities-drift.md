# i29 capabilities.json drift — canonical_projection fence

Date: 2026-10-18 22:48 PDT · Context: pair(i29-full-soak-c lane, canonical projection fence)

Standing: **PASS** (drift diagnosed, sanctioned regen applied, fence green x2)

## Symptom

`test/canonical_projection_test.exs:134` "docs/capabilities.json is stale vs
Registry truth" failed even in isolation; file was byte-identical to HEAD.
Reproduced solo:

```
MIX_BUILD_ROOT=_build-ft-cap1 mix test test/canonical_projection_test.exs
20 tests, 1 failure   (seed 349860, only the :134 fence)
```

## Root cause — committed-truth-side, NOT in-flight

`git status` of `lib/smalt/registry.ex`, `docs/capabilities.json`,
`docs/THIRD_PARTY.md` was clean vs HEAD — no uncommitted registry regen.
Offline (no-compile) type-set comparison: HEAD registry
`@admitted_resource_types` = 41 types, doc `capabilities` = 41, symmetric
difference empty. The drifting key was **identity**:

```
docs/capabilities.json identity.packLockSha256 = 9cb0aded99689c57...  (pre-repin lock)
on-disk ggen_igniter.pack.lock sha256        = 532b495a89f77535...  (repin a8e8867)
```

Commit a8e8867 ("repin ggen_igniter.pack.lock to live marketplace identity
a454f2f0") changed `ggen_igniter.pack.lock` AFTER the last
`Canonical.write` (8552eec) — `Smalt.Projection.Canonical.json/0` digests
the pack lock from disk into `identity.packLockSha256`, so the committed
artifact went stale against committed truth. The full-diff of the regen is
exactly the two identity digests (contentSha256 + packLockSha256);
capabilities list, endpoints, third_party all unchanged.

## Fix (sanctioned)

```
MIX_BUILD_ROOT=_build-ft-cap1 mix run --no-start -e 'Smalt.Projection.Canonical.write()'
# exit 0; git status: only docs/capabilities.json modified
```

Verification, fence green twice on build root `_build-ft-cap1`:

```
mix test test/canonical_projection_test.exs   # 20 tests, 0 failures
mix test test/canonical_projection_test.exs   # 20 tests, 0 failures (rerun)
```

## Notes

- One transient compile freeze was observed mid-investigation:
  `lib/smalt/messaging/amqp/atom_bridge.ex` (in-flight i29 s4-amqp-capacity
  lane) briefly had a syntax error at 22:45; it compiled clean by 22:47
  (`mix compile --warnings-as-errors` exit 0). No action taken on that file
  by this lane.
- Coordinator: `docs/capabilities.json` regen rider needs to ride the next
  commit (one file, identity digests only). No code change.
- HEAD moved during the lane (a8e8867 -> b9a6dc1, concurrent i29 commits);
  the fence verdict is unchanged on the new head.
