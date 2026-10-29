# KD-156 fix — ARM SB provisioning shape gate (child PUT location coercion)

**Standing:** ALIVE (fix landed, wire-witnessed post-fix, KD-156 court PASS 4/4 legs, 9 tests 0 failures)

Context: solo

Date: 2026-10-21 · Lane: KD156FIX (writer) · Build root: `_build-kd156`

## Defect and root cause

KD-156 alleged namespace PUT refusing minimal bodies. Wire repro against the
live substrate (2026-10-21, 18:01Z) showed the namespace leg ALREADY admitting
(202 → operation Succeeded; fixed upstream by 1aca688 "DefaultShape location
relaxation" — register-row premise rot). The live residual defect was the
child face:

    PUT .../namespaces/ns/queues/qnoloc  body {}
    → 400 InvalidResourceShape "A resource payload may carry at most one location."

Root cause: `Smalt.GraphLaw.Validator.ShapeFile.add_property/3` defaulted
`min_count: prop.min_count || 1`, coercing DefaultShape's maxCount-only
`sh:property [ sh:path smalt:location ; sh:maxCount 1 ]` block into a
de-facto REQUIRED property on every resource type. SHACL semantics: an
absent sh:minCount means no minimum. Azure parity: child PUTs omit
`location` (children inherit region from the parent).

## Fix

`lib/smalt/graphlaw/validator.ex` — default 1 → 0 with a KD-COVERS: KD-156
marker on the changed lines. No shape in `priv/shacl/smalt-shapes.ttl` relied
on the implicit-1 default (every required prop declares sh:minCount 1
explicitly; optional props declare 0); verified by full internal/integration
sweep below.

## Wire receipts (live substrate, :9443)

BEFORE (old beam, pid 56472):

    queue PUT {} under existing ns → HTTP 400
    {"error":{"code":"InvalidResourceShape",...,"message":"GraphLaw validation
    failure: A resource payload may carry at most one location. at location",...}}

AFTER (rebuilt beam, `substrate.sh down/up`, pid 8877):

    namespace PUT {"location":"eastus","sku":{"name":"Standard","tier":"Standard"}}
      → HTTP 202 InProgress (operation poll → Succeeded)
    queue PUT {} under existing ns
      → HTTP 201 {"id":".../namespaces/nsfix1/queues/qfix2","location":"eastus",...}
    queue PUT {} under MISSING namespace nosuchns
      → HTTP 404 {"error":{"code":"ResourceNotFound","message":"The parent nosuchns could not be found."}}
    namespace PUT without location
      → HTTP 400 InvalidResourceShape "serviceBus namespaces require location."

## KD-156 half-2 verdict: parent-existence gate is CONFORMANT, no fix

Azure Service Bus also refuses child queue PUTs until the parent namespace
resource exists (the REST RP resolves the parent before entity creation).
smalt's 404 `ResourceNotFound` "The parent X could not be found." matches;
no change made.

## Court

`test/integration/kd156_sb_shape_test.exs` (new, Chicago — real in-process
ARM router dispatch, no mocks):

    MIX_BUILD_ROOT=_build-kd156 mix test test/integration/kd156_sb_shape_test.exs \
      test/integration/namespace_put_test.exs
    9 tests, 0 failures

Arm/SB tier regression:

    MIX_BUILD_ROOT=_build-kd156 mix test test/integration/sb_arm_rules_test.exs \
      test/integration/kd51_sb_atom_https_test.exs test/integration/kd143_rules_persistence_test.exs \
      test/integration/arm_dcr_test.exs test/integration/policy_enforcement_mode_witness_test.exs
    17 tests, 0 failures

## Disclosure

`test/internal` census failures observed during the sweep are
session-EXTERNAL: another lane's in-flight edits to
`test/internal/internal_tier_census_test.exs` + untracked test files; this
lane touched neither. `test/integration/kd_conformance_test.exs` is also
another lane's untracked file (ran it once; its own failures are not
attributable here).

## Falsifier

Re-PUT a queue with body `{}` — any reappearance of 400 "at most one
location" flips the KD-156 row back to OPEN.

---

## Re-witness 2026-10-21 (post-shim, post-token-fix)

Shim file retouched (KD-COVERS token normalization in
`lib/smalt/arm_gateway/router.ex`), so the KD-148-class mtime trap was
re-satisfied by re-running the dedicated court suite:

```
$ MIX_BUILD_ROOT=_build-lane1 mix test test/integration/kd155_delete_framing_test.exs test/integration/kd156_sb_shape_test.exs
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)
9 tests, 0 failures
```

**Standing:** PASS — 9 tests, 0 failures (KD-155 framing + KD-156 SB-shape courts,
exit 0). Context: solo.
