# BK-ASSERTG — BK-TOPO WI-1: env-typed allowlist (SMALT_ALLOWED_HOSTS)

Standing: ALIVE · Context: solo · 2026-10-22

## What landed

- `workspace/lib/smalt.ts` — `assertLocalUrl` gains an env-typed allowlist:
  `SMALT_ALLOWED_HOSTS` (comma-separated hostnames; trimmed, lowercased,
  empty entries dropped) is admitted alongside loopback when non-empty.
  Unset / empty / whitespace-only ⇒ byte-identical loopback-only posture
  (same hosts array, same refusal message). No wildcards — named hosts only;
  case-insensitive match on the URL hostname. Exports `LOOPBACK_HOSTS` and
  `allowedHosts()` for court reuse.
- `workspace/lib/caller-gate.ts` — `assertLoopbackCaller` (Host header and
  Origin hostname) uses the same env allowlist via a `hostAllowed()` helper;
  the gate is widened, never disabled — when the env is unset the check is
  byte-identical, and a non-named host is still 403 `sync_state_non_loopback`
  even with the env set. Secret half (`SMALT_BFF_SYNC_SECRET`) untouched.
- `workspace/test/smalt_allowlist.test.ts` — new Chicago court (node --test,
  no mocks; the real functions exercised with the real env var, restored in
  a `finally`): 10 legs, all green.
- `k8s/smalt-console.yaml` — handwritten console manifest now sets
  `SMALT_ALLOWED_HOSTS=smalt-backend.default.svc.cluster.local` (the backend
  ClusterIP the ARM/egress env values already point at) and the typed-seam
  comment block is replaced by the landed wiring doc.

## Court output (embedded)

```
✔ env unset -> loopback admitted (byte-identical default) (…)
✔ env unset -> non-loopback refused with Air-gap violation (…)
✔ env empty string -> loopback-only (byte-identical default) (…)
✔ env whitespace-only -> loopback-only (…)
✔ env set -> witness kind-console service DNS admitted (…)
✔ env set -> non-named host still refused (no wildcard egress) (…)
✔ env set -> caller-gate env set -> allowed Host header proceeds (…)
✔ caller-gate env set -> allowed Origin proceeds, non-named Host 403 (…)
✔ caller-gate env unset -> non-loopback Host still 403 (gate never disabled)
ℹ tests 10 · pass 10 · fail 0 · skipped 0
```

Non-vacuity legs: env unset → witness host `smalt-console.default.svc.cluster.local`
(the kind-console cell's service DNS) refused with `Air-gap violation`; env
set → it is admitted; a subdomain of an allowed host and `evil.example.com`
stay refused; caller-gate refuses with 403 `sync_state_non_loopback` when the
env is unset.

Witness admission: `http://smalt-console.default.svc.cluster.local:9443/arm/locations`
parsed to `hostname == smalt-console.default.svc.cluster.local` under the env
set.

## Adjacent gates

- Existing `app/api/sync/state/route.test.ts`: 8 pass / 0 fail / 2 loud SKIP — unchanged.
- Strict tsc over both lib files: clean. ESLint over both lib files + the
  court: clean (raw-fetch ban intact — traffic still only via `smaltFetch`).
- `ws-court` (e2e-court.mjs) static legs: **70 PASS / 0 FAIL / 2 loud SKIP**
  (incl. `smalt.ts` + `caller-gate.ts` typecheck+import). Its leg 5
  (kd173c ingest dev-plane legs) crashes booting its own dev server because
  a **pre-existing** `next-server` (PID 52372, started 10:26 today, not
  spawned by this lane) holds the workspace dev lock on :3000 —
  environmental, present before this diff; not killed (shared checkout, not
  this lane's process). `just` itself currently cannot parse
  `justfile.d/53-trivy.just` (another lane's in-flight file; pre-existing),
  so the court was run directly (`NODE_PATH=… node scripts/e2e-court.mjs`).
- Pre-existing, unrelated: `test/airgap_egress.test.ts` fails at import with
  `ERR_MODULE_NOT_FOUND` (`../src/lib/airgap-fetch.js` never resolves under
  node type-stripping) — it imports neither of this lane's files.

## Falsifier status

TOPOLOGY-MATRIX F5/F6 guard-side legs close with this diff (the guard now
admits named hosts exactly when the operator names them); the in-cluster
falsifier runs themselves remain BK-TOPOV's lanes (kind boot + real pod
fetch).
