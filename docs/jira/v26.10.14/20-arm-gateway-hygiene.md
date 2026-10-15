# V261014-20 — ARM Gateway Hygiene: route-citation refresh, duplicate PUT dedupe, If-Match value verification

- **Release:** v26.10.14
- **Lane:** ARM gateway (beyond LRO lane 05; the api-version fence is complete and fenced — no fence work here)
- **Owned files:** `test/apiversion_matrix_test.exs`, `test/azapi_actions_test.exs`, `lib/smalt/arm_gateway/router.ex` (only under Decision (a)), `test/lro_test.exs` (optional item 4), WIRE_PARITY/C1 (only under Decision (b))

## 1. Background

The api-version fence is complete: latest-version-only admission for admitted types, presence-only gates elsewhere, LRO poll deliberately versionless with the pinned exemption at `router.ex:1183-1184`. Nothing remains on that lane. This order covers hygiene debt: stale file:line citations breaking a moduledoc contract, a duplicated PUT in the matrix harness, and an If-Match verification gap on the azapi lock precondition.

## 2. Work items

### 2.1 Refresh stale router.ex route citations (must)

`test/apiversion_matrix_test.exs:26` promises "each row cites the router file:line of the PUT route it exercises" — now false.

| Location | Stale cite | Correct target |
|---|---|---|
| `:41` (`@generic_put_line`) | `router.ex:954` (comment above still says 794) | `router.ex:1766` (generic provider PUT); fix attribute + comment |
| `@child_routes` (:129-143) | `:754`, `:771`, `:788`, `:801`, `:818` | `:1315`, `:1356`, `:1397`, `:1428`, `:1469` (row order) |
| `@parented_routes` (:149-170) | `:858`-`:926` | `:1510`, `:1559`, `:1608`, `:1657`, `:1706` (row order) |

Also refresh `test/azapi_actions_test.exs` stale cites (`:36-38`, `:49`, `:89-90`, `:98`, `:103-104`): `handle_action` is now at `router.ex:876`; the POST glob route at `router.ex:1811`. Re-verify each neighboring citation at edit time.

**2.1a (recommended companion) Cite-drift fence.** Meta-test asserting each `router.ex:LINE` citation resolves to a line whose content matches the expected construct (e.g. `handle_child_put`, `handle_parented_child`, generic PUT match head). Converts the moduledoc promise from prose into an enforced invariant: future router insertions turn the fence red instead of silently rotting citations.

### 2.2 Dedupe double PUT in matrix `create/3` (must)

`test/apiversion_matrix_test.exs:93-100` — `create/3` calls `put_resource/4` twice with identical arguments, discarding the first. Delete the first call. Pure harness cleanup; behavior unchanged (idempotent PUT).

### 2.3 azapi lock If-Match: value verification (decision gate)

Current: `check_lock_precondition/2` (`router.ex:915-927`) treats If-Match as presence-only — any non-empty header passes; a **mismatched** etag yields 200 where real Azure returns 412 PreconditionFailed. `test/azapi_actions_test.exs:70-79` pins this as "pinned actual."

**Decision (a) — implement value-verified If-Match (RECOMMENDED).**
- In `check_lock_precondition/2`, when If-Match is present, compare against the stored etag of the immutability policy resource; mismatch → inline 412 PreconditionFailed envelope (same envelope shape as the missing-header case — keep inline, NOT `send_arm_error`, since the arm_error_corpus meta-test pins the (status, code) set and PreconditionFailed/412 must stay out of it). Honor `*` as always-match per RFC 7232.
- Update the pin: "wrong If-Match → 412", `conn.status == 412`, `body["error"]["code"] == "PreconditionFailed"`; keep a matching-etag → 200 case.
- Acceptance: 412 over real `Router.call/2` dispatch (not unit-only).
- `router.ex` in-scope only under (a).

**Decision (b) — tokenize the gap.** Add `GAP(azapi-lock-if-match-unverified)` to WIRE_PARITY + C1; leave the "pinned actual" test with a comment linking the token. No router change.

### 2.4 Optional: `wait_terminal` clarity

`test/lro_test.exs:918-921` — reorder the flunk-then-sleep sequence so the failure message fires before the terminal sleep; intent (poll until terminal, flunk with state dump on timeout) explicit. Cosmetic; take only if the file is touched anyway.

## 3. Sequencing

1. 2.1 citations + 2.1a fence (test-only; the fence verifies 2.1).
2. 2.2 dedupe (test-only).
3. 2.3 decision (a) + pin update, or (b) tokenization.
4. 2.4 optional, last.

No inter-WO dependencies; independent of lane 05 provided the versionless-poll exemption (`router.ex:1183-1184`) is untouched.

## 4. Acceptance criteria

- Cite-drift fence green; every refreshed citation resolves to a line matching the expected construct.
- `mix test test/apiversion_matrix_test.exs test/azapi_actions_test.exs test/route_negative_test.exs` green.
- Decision (a): real-dispatch If-Match mismatch → 412 PreconditionFailed; matching etag → 200; the "pinned actual" behavior replaced.
- Decision (b): `GAP(azapi-lock-if-match-unverified)` present in WIRE_PARITY + C1; existing pin unchanged.
- No behavior change to the api-version fence or the LRO poll exemption.
