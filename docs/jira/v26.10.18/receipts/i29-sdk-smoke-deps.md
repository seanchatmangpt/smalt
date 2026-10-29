# Receipt: i29-sdk-smoke-deps — sdk-smoke dependency manifest

Context: solo(checkpoint2 census follow-up)

Date: 2026-10-18 · Context: solo(checkpoint2 census follow-up)
**Standing:** PARTIAL_ALIVE

## Diff audited

- `test/sdk-smoke/package.json` (tracked, modified): adds `dependencies`
  `@azure/cosmos ^4.10.1`, `@azure/event-hubs ^6.0.4`,
  `@azure/service-bus ^7.10.0`.
- `test/sdk-smoke/package-lock.json` (untracked, new): lockfile minted by the
  same `npm install` (22:28/22:39 today).

## Verdict: LEGITIMATE — keep

Every `.cjs` test in the directory requires these packages:

```
$ grep -rln "@azure" test/sdk-smoke --include="*.cjs"
amqp.test.cjs blob.test.cjs census.test.cjs cosmos.test.cjs eventhubs.test.cjs sb-extra.probe.cjs
```

Resolution witness (all three resolve from the lane's own node_modules):

```
$ node -e "...require.resolve(p,{paths:['/Users/sac/smalt/test/sdk-smoke']})"
@azure/cosmos        → test/sdk-smoke/node_modules/@azure/cosmos/dist/commonjs/index.js
@azure/event-hubs    → test/sdk-smoke/node_modules/@azure/event-hubs/dist/commonjs/index.js
@azure/service-bus   → test/sdk-smoke/node_modules/@azure/service-bus/dist/commonjs/index.js
```

The smoke harness itself (`run.mjs`) uses only node builtins and honors
`SMALT_SDK_ROOT`; the declaration makes the previously ad-hoc node_modules
reproducible.

## Verification attempt (honest)

Live-fire re-run was port-blocked, not dep-broken:

```
$ node test/sdk-smoke/run.mjs
[sdk-smoke] port 9443 is occupied. Do NOT kill the holder...
TRUE_EXIT=3        # harness-skip, loud per exit-code contract
```

Holder: `ssh` pid 61023 listening on 9443/8443 (tunnel, not a smalt beam).
A direct `node --test cosmos.test.cjs` with `SMALT_SDK_ROOT` set against the
tunnel endpoint failed with `RestError: ECONNRESET socket hang up` — backend
dead, again transport not dependencies. Per port law the holder was left
untouched.

## Related cluster member: REVERT-CANDIDATE (root)

`/Users/sac/smalt/package.json` + `/Users/sac/smalt/package-lock.json`
(untracked, new, same timestamps) declare only cosmos + event-hubs and are an
npm-install byproduct of some lane running npm from the repo root. Nothing
committed needs them: the smoke harness resolves without them, and root-level
probes (`test/sdk-full/*.mjs`, `test/data_plane/sdk_probe.mjs`) take
`SMALT_SDK_ROOT`. No root-level committed code imports @azure via root
resolution. Recommend revert (delete the two root files); not reverted here —
reporting only, per lane scope.
