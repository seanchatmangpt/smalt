# SF1: GCP review-defect fixes

Standing: PARTIAL

Lane SF1. Source: docs/gcp-parity/REVIEW-GS.md. Nothing compiled or run (no mix/just/git by order).

## Fixes applied (all files re-read after edit)

1. pubsub.ex valid_name regex: `~r{...}` -> `~r|...|`.
2. pubsub_engine_test / pubsub_router_test: dropped `start_supervised!`; setup `PubSub.reset()` + on_exit reset.
3. pubsub_router_test: ids `tr`/`sr` -> `tr1`/`sr1`.
4. pubsub_router_test: maxMessages 0 test now creates topic `top` + sub `sub1` first.
5. logging.ex: insertId zero-padded to 20 digits (monotonic).
6. storage/router.ex: removed second CRLF strip (`data = part_body(p2)`).
7. storage.ex: empty `delimiter` guarded (`delim not in [nil, ""]`).
8. storage/server.ex: `fun.(st)` wrapped in try/rescue -> typed 500 error, state kept.
9. firestore.ex: run_query validates from.collectionId (400) then `do_run_query`.
10. identity.ex: `key/0` serialized with `:global.trans` + re-check.
11. firestore/router.ex `:_db`: left unchanged (conditional on a compile warning; UNVERIFIED).

## Additional

- SecretManager/KMS: `start_link(opts \\ [])`, default `name: __MODULE__`; `name: nil` = unnamed.
  `start_link/0` still valid, so SW1 child specs in application.ex need no change. Tests use
  `start_link(name: nil)` to avoid colliding with the app-started named Agents.
- Plug.Test host set: pubsub/firestore/storage/run-logging router tests set conn.host to the
  matching googleapis host.

## Remaining UNVERIFIED

- Compile and `mix test test/gcp` not run.
- REQUIRED one-line change outside my tree: lib/smalt/egress_router.ex `gcp_engine/1` (and
  gcp_spawn_engine) now calls `mod.start_link()` which returns `{:error, {:already_started, _}}`
  when the app child is up. Replace gcp_engine body with `mod` (Agent calls accept the registered
  name) or `Process.whereis(mod)`.
- Defect 11 unchecked.
