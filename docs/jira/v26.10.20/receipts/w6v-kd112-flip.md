# w6v — KD-112 KD-COVERS token + flip attempt

**Standing:** PARTIAL_ALIVE (token landed; flip typed-REFUSED, pending post-token re-witness)

Date: 2026-10-20
Lane: w6v (mechanical, wave-6)
Subject: smalt working tree, 2026-10-20 (uncommitted wave-6 churn)

## What landed

- `lib/smalt/arm_gateway/router.ex`: added `# KD-COVERS: KD-112` (own line,
  exact token format) immediately above the `# Policy set definitions
  (initiatives, subscription scope)` block — the surface the real-PolicyClient
  witness (KD-112) exercised. One-line additive diff.

```
$ grep -rn "KD-COVERS: KD-112" lib/
lib/smalt/arm_gateway/router.ex:5579:  # KD-COVERS: KD-112
```

## Flip verdict (real output)

```
$ python3 scripts/kd_flip.py --apply | grep -A3 "FLIP-PENDING\|FLIP-ELIGIBLE"
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-112: no post-shim receipt newer than shim mtime (2026-10-20T06:53:07)
--apply: nothing FLIP-ELIGIBLE; register unchanged.
```

Diagnosis: the tool is CORRECT. The token insertion (06:40, since re-touched by
sibling lanes' concurrent edits to the same file — tool reads current mtime
06:53) postdates the KD-112 witness receipt (06:21). Per the register law the
flip is gated on a PASS witness receipt NEWER than the shim; the KD-117
precedent applies: a post-token re-witness addendum is required, with real
embedded output.

## Prepared but not executed: post-token re-witness leg

`tmp/w6v_verify.exs` (on disk, replayable) — module-direct `mix run --no-start`
against the real Store exercising the covered surface (put/get/list
policySetDefinitions). It could not run: the shared tree has been compile-frozen
by sibling lanes' in-flight files for the whole lane window (observed breakers,
in order: table_storage.ex:295, table_storage_router.ex:38, monitor/metrics.ex:299,
cosmos_authz_plug.ex:56 — all with fresh mtimes from active owners; none mine,
no unblock fixes applied per exclusive-ownership law).

## Next action (coordinator)

When the tree compiles green: `MIX_BUILD_ROOT=_build-lane-w6v mix run --no-start
tmp/w6v_verify.exs` → append its output as an addendum to
`docs/jira/v26.10.19/receipts/kd112-arm-policy-initiatives-tbd.md` → re-run
`python3 scripts/kd_flip.py --apply` → expect KD-112 CLOSED-SIMULATED.

Falsifier: if the verify script errors, the flip stays refused and KD-112
remains OPEN.
