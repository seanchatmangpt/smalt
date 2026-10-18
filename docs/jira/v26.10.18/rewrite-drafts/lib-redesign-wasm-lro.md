# lib redesign drafts: WasmEngine + LRO (distilled clean, 2026-10-18)

## Part 1 — WasmEngine supervised-restart (zero caller-path sleeps)

Design: dedicated `Smalt.Affidavit.WasmEngine.Supervisor` (one_for_one,
max_restarts 3 / max_seconds 1), additive child of Smalt.Supervisor. Engine
init already stops with {:stop, :engine_start_failed} (wasm_engine.ex:395) —
supervised restart IS the retry; intensity is the backoff. Caller path:
whereis probe → typed {:error, :engine_unavailable} on miss; retry-capable
callers (doctor) monitor the name and schedule send_after retries in their
OWN mailbox, backoff doubling capped.

Receipted invariants preserved: typed fail-closed vocabulary
({:error, :engine_unavailable} / :artifact_digest_mismatch) never raise;
artifact refusals refuse FAST with zero sleep (admission pipeline stays
eager); already_started passthrough (lane644 face) becomes the supervisor's
guard; DEF-1 last_init_refusal/0 seam re-persists verbatim on every
supervised attempt (doctor.ex:494 consumes it).

Fence conversion: with the sleep gone, fence10-ratio.md's ratio fence has no
subject → fence 10 becomes STRUCTURAL (zero Process.sleep in the engine
module) and the lane644 restart-hammer converts to a supervised-restart
hammer: kill-loop under load, callers observe only typed vocabulary +
already_started passthrough.

## Part 2 — LRO explicit completion signal (one writer, owned convergence)

Today: evaluate/2 called from TWO concurrent writers (get_op read path +
Sweeper.flip_pass); convergence is emergent (same pure function + atomic
insert), byte-identity load-bearing. Redesign (Option A): single terminal
writer — the sweeper publishes terminal via explicit cast through a new
`LRO.Notifier` GenServer (op_id → monitored waiters); `LRO.await(op_id,
timeout)` = store-first fast path + register + receive; the poll path becomes
a pure reader (never writes).

Properties: one-terminal convergence becomes OWNED not emergent; byte-identity
stays as harmless idempotence; wire contract unchanged (202 + Retry-After,
bounded staleness ≤ sweep interval, dominated by Azure's 60s Retry-After
floor); notifier-down is fail-safe (store-first fallback; sweeper still flips
at rest — signal layer is optimization, never correctness).

Invariants preserved (cited): one-terminal convergence fence 10d
(lro_test.exs:728-762) stays GREEN; read-path fail-closed for malformed
records (lens-10 receipts) stays, routed through the single writer or
disclosed as the one exception; evaluate/fail_closed stay PUBLIC as the sole
terminal-transition authority; store-key persistence (never record["name"],
lens-9); never wedge in InProgress; InProgress never evicted (incl. retention
0); subscription-scoped deny-by-default awaiter registration; config gates
stay; no process-lifetime coupling (lro.ex moduledoc).

Add: notifier-down face fence (kill Notifier mid-await → typed timeout,
store converges via at-rest flip).
