# KD-56 witness — ARM provider register/unregister + providerPermissions (FIX)

**Standing:** ALIVE (fix landed, wire-witnessed; FLIP-ELIGIBLE)

Row: KD-56 — register/unregister + providerPermissions missing.
Subject: `lib/smalt/arm_gateway/router.ex`

## Disposition

SPLIT. register/unregister (`POST .../providers/:ns/register|unregister`) was
already on the wire (read-only enclave truth: register -> "Registered",
unregister -> "Unregistering", GETs keep "Registered") — witnessed live, no
edit needed for that half. Lane K4 added the missing half:
`GET /subscriptions/:sub_id/providers/:ns/providerPermissions` with a
`# KD-COVERS: KD-56` marker (read-only enclave truth: one `*` allow row; no
RBAC store exists).

## Evidence (lane K4 substrate on :39551, 2026-10-01/21)

```
== KD56 register
{"namespace":"Microsoft.Storage","registrationState":"Registered","resourceTypes":[...]}
== KD56 providerPermissions
{"value":[{"actions":["*"],"dataActions":[],"noActions":[],"noDataActions":[]}]}
```

Row falsifier (`providers.add()` -> 200 Provider with registrationState
"Registered") passes; providerPermissions no longer 404s.

## Regression check

Same as KD-55 receipt (shared run: 8 tests, 0 failures on the ARM generic-route
suites; error-corpus failures are concurrent-lane, not ARM surface).

## Flip

FLIP-ELIGIBLE (dry-run only; flip via `scripts/kd_flip.py --apply`, gated on
receipt mtime).

Verdict: PASS (falsifier of the row executed on the wire; output above).
