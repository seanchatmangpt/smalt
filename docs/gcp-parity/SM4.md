# SM4 Functions/Run Invocation + Cloud Tasks Receipt

Standing: UNVERIFIED

Authoring lane only: no mix/just/git was run; nothing compiled or tested.

## Files
- lib/smalt/gcp/functions.ex (Functions v2 CRUD, `call/4`, `invoke_service/5`, `run_handler/2`)
- lib/smalt/gcp/cloud_tasks.ex (queues, tasks, `run_task/4`, `drain/3`)

## Typed divergences
Handlers are in-VM `"Elixir.Mod.fun"` arity-1 functions, not containers; no scheduler,
backoff, or HTTP targets for tasks; tasks run only on explicit run/drain.

## Unwired
No router, no tests (Store keys/1 return shape assumed to be key list). Coordinator gates.
