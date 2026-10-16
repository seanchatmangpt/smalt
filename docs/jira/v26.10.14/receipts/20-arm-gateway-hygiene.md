# Receipt — V261014-20 lane 20 (ARM Gateway Hygiene)

Date: 2026-10-15 · Checkout: /Users/sac/smalt (main, no commits made) · Owner: lane 20

## Executed

### 2.1 Route-citation refresh
- `test/apiversion_matrix_test.exs`: `@generic_put_line` → `router.ex:1798`; `@child_routes` cites → `:1347/:1388/:1429/:1460/:1501`; `@parented_routes` cites → `:1542/:1591/:1640/:1689/:1738`; comments refreshed (`:973` locks literal, generic PUT comment).
- `test/azapi_actions_test.exs`: all router.cites refreshed (POST glob → `:1791`, action_envelope lock/setlegalhold → `:968`/`:980`, handle_child_put/get `:689`/`:717`, handle_resource_put `:611`, check_version `:1018`, generic PUT/DELETE `:1798`/`:1829`, Registry cites `:20/:27/:33` + versions `:100-139`).

### 2.1a Cite-drift fence
- Added `cite-drift fence` test in `test/apiversion_matrix_test.exs` (`@cite_drift`, 12 rows: 11 routes + locks literal). Each `router.ex:LINE` citation is re-read from the file at test time and must match its expected construct. **Fence witnessed firing during the session**: a concurrent lane inserted 32 lines into router.ex mid-run, the fence went red (`router.ex:1315` resolved to `"resourceTypes" =>`), citations were re-derived from the current file, and it went green. The moduledoc promise is now enforced.

### 2.2 Dedupe
- `create/3` double `put_resource/4` in `test/apiversion_matrix_test.exs` collapsed to a single call. Behavior unchanged (237 tests green).

### 2.3 Decision (a) — value-verified If-Match
- `lib/smalt/arm_gateway/router.ex` `check_lock_precondition/2` (lock clause, ~:915 region at edit time): present-but-mismatched If-Match now → inline 412 PreconditionFailed via `send_json` (NOT `send_arm_error`; arm_error_corpus pinned set unchanged — verified: `mix test test/arm_error_corpus_test.exs` 15 tests, 0 failures). `*` honored as always-match (RFC 7232). New public `Router.lock_policy_etag/1`: quoted uppercase-hex MD5 of the request path minus trailing `/lock`, downcased (mirrors blob-service etag form); deterministic, so tests compute the real etag.
- `test/azapi_actions_test.exs` pins replaced:
  - "wrong If-Match → 200 (pinned actual)" → "wrong If-Match → 412 PreconditionFailed (value-verified)".
  - Lock test now sends `Router.lock_policy_etag(lock_request_path())` → 200.
  - New `If-Match *` → 200 always-match case.
- All three drive real `Router.call/2` dispatch (not unit-only).

### 2.4 — SKIPPED (no-op)
- Lane 05's `test/lro_test.exs` rewrite is already on disk (+517/-14); the cited flunk-then-sleep at `:918-921` no longer exists in that form and the current `wait_terminal/2` already flunks before the terminal sleep (`:1058` flunk precedes `:1060` sleep). Per dispatch guard, left untouched.

## Verification (real output)

- `mix test test/apiversion_matrix_test.exs test/azapi_actions_test.exs test/route_negative_test.exs` → **237 tests, 0 failures** (exit 0).
- `mix test test/arm_error_corpus_test.exs` → 15 tests, 0 failures (envelope-set fence intact).
- Acceptance: mismatched If-Match → 412 PreconditionFailed and matching etag → 200 over real `Router.call/2`; `*` → 200; cite-drift fence green.

## Cross-lane notes (disclosed)
- Compile-freeze unblock attempt: `lib/smalt/messaging/amqp/management_rpc.ex` (lane-12/08 file, not owned) briefly broke the shared compile (`queue_from_request` undefined in a stub clause). Before my minimal fix landed, the owning lane fixed it on disk; my edit was NOT applied. Net: no foreign-file changes by this lane.
- router.ex drifted +32 lines mid-session (another lane's insertion); citations and fence were re-derived from the current file — all cites verified against the on-disk router.ex at final edit time.
- `test/lro_test.exs`, `docs/compliance/C1_ARM_REST.md`, `docs/WIRE_PARITY.md` untouched (lane 05 ownership).

## Standing
- ALIVE for this lane's scope: all acceptance criteria executed and passing on the current shared tree.
- Residual risk: further concurrent router.ex insertions will re-drift cites; the new fence turns that red instead of silent.
