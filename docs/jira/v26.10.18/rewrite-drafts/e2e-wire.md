# Rewrite drafts — e2e + wire consolidation (v26.10.18)

Standing: DRAFT — no edits made; tree read-only. All receipted verdicts
(s6 `EXACTLY_ONCE_OK`, s9 LRO chain, wire-tier censuses) are preserved
verbatim in every draft: same receipt contract, same exit-code contract,
same ports, same assertions.

Read from disk this session: `test/e2e/s6_checkpoints/checkpoint_chain.exs`
(163L, post-batch4 try/after), `test/e2e/s9_lro_chain/run.sh` (88L) +
`lro_chain.test.mjs` (poll loop at L122), `test/wire/egress_wire_test.exs`
(1105L), `test/wire/amqp_wire_test.exs` (164L),
`test/runtime_contracts_test.exs` (679L),
`test/zero_drift_serialization_test.exs` (285L),
`test/test_helper.exs` (`SmaltTest.Lifecycle`),
`docs/jira/v26.10.17/receipts/i21-leak-batch4.md`.

## D1. Canonical env-snapshot helper — `SmaltTest.PortEnv`

### Problem

The leak-gate save-prev/restore discipline is hand-duplicated 5+ times with
drift already visible:

| file | keys saved | restore call shape |
|---|---|---|
| `test/e2e/s6_checkpoints/checkpoint_chain.exs` L20-26, L138-158 | 5 port keys | inline 5-key if/else, delete_env-when-nil |
| `test/wire/egress_wire_test.exs` L27-60 | 3 keys | inline if/else + restore_app + ensure_store_up |
| `test/wire/amqp_wire_test.exs` L30-75 | 4 keys | inline if/else + restore_app + ensure_store_up |
| `test/runtime_contracts_test.exs` L31-39 | auth_mode, lro_delay_ms | `put_env(prev)` even when prev was nil (writes `nil` back — a live bug class the delete_env-when-nil files already fixed) |
| `zero_drift_serialization_test.exs` L34-42 | lro_delay_ms | delete_env-when-nil (correct) |
| `test/wire/arm_wire_test.exs`, `wire_tier_refusal_sweep_test.exs` | 3-4 keys | same inline pattern (batch4 lease) |

Drift proven: `runtime_contracts_test.exs` L37-38 uses bare
`put_env(k, prev)` with no nil clause — restoring `nil` into
`Application.put_env` silently stores the literal `nil` as the value, which
differs from "key absent" for any code path that reads
`get_env(k, default)`. The helper fixes this once, everywhere.

### Draft: new `test/support/port_env.ex`

```elixir
defmodule SmaltTest.PortEnv do
  @moduledoc """
  Canonical save-prev/on_exit-restore discipline for :smalt Application-env
  mutations (test-isolation-leak gate, i21-leak-batch4 pattern).

      prev = SmaltTest.PortEnv.snapshot([:arm_port, :egress_port])
      SmaltTest.PortEnv.apply(arm_port: 19443)
      on_exit(fn -> SmaltTest.PortEnv.restore(prev) end)

  Nil-preserving: a key that was absent is deleted on restore, not written
  as literal nil (fixes runtime_contracts_test.exs L37-38 drift).
  """

  @keys [:arm_port, :arm_tls_port, :egress_port, :amqp_port, :event_hubs_port,
         :auth_mode, :lro_delay_ms, :maa_measurement_baseline]

  def snapshot(keys), do: Map.new(keys, &{&1, Application.get_env(:smalt, &1)})

  def apply(kvs), do: Enum.each(kvs, fn {k, v} -> Application.put_env(:smalt, k, v) end)

  def restore(prev) do
    Enum.each(prev, fn
      {k, nil} -> Application.delete_env(:smalt, k)
      {k, v} -> Application.put_env(:smalt, k, v)
    end)
  end
end
```

Nil-preserving by construction: absent key restores to absent.

### Call-site rewrites

- **`checkpoint_chain.exs`** (mix-run script, no ExUnit/test_helper): the
  helper must be loadable without test_helper. Two options:
  - **D1a (preferred)**: keep the module in `test/support/port_env.ex` and
    have the script require it:
    `Code.require_file("test/support/port_env.ex", File.cwd!())` at the top
    of checkpoint_chain.exs, then
    `prev = SmaltTest.PortEnv.snapshot([...5 port keys])` and replace
    L138-158 with `SmaltTest PortEnv.restore(prev)` inside the existing
    `after`. Try-body semantics unchanged: `prev` bound before `try` (the
    batch-2 scoping law), body returns `{exit_code, receipt}`, receipt
    write + `System.halt` stay after the try.
  - **D1b (alternative)**: leave checkpoint_chain.exs inline but reduce the
    inline block to a private 4-line
    `restore_envs = fn prev -> Enum.each(prev, fn {k, nil} -> ... end) end`
    — strictly less desirable; keeps the duplication.

- **Wire tests** (`egress_wire`, `amqp_wire`, `arm_wire`,
  `wire_tier_refusal_sweep`): setup becomes

  ```elixir
  prev = SmaltTest.PortEnv.snapshot([:arm_port, :egress_port, :amqp_port])
  SmaltTest.PortEnv.apply(arm_port: get_free_port(), egress_port: ports.egress, ...)
  on_exit(fn ->
    SmaltTest.PortEnv.restore(prev)
    SmaltTest.Lifecycle.restore_app()
    SmaltTest.Lifecycle.ensure_store_up()
  on_exit
  ```

  key order in `restore` is snapshot order — deterministic.

- **`runtime_contracts_test.exs`**: snapshot `[:auth_mode, :lro_delay_ms]`;
  the nil-preserving restore *changes behavior here* (nil restore becomes
  delete_env) — that is the fix, called out explicitly for the receipt:
  the current code re-puts `nil`, which is not byte-identical to
  "key absent" for `get_env(k, default)` readers. Verify post-rewrite that
  the suite is green under `mix test test/runtime_contracts_test.exs`.

- **`zero_drift_serialization_test.exs`**: mechanical swap onto
  `snapshot([:lro_delay_ms])` / `restore(prev)` — behavior-identical.

### Verification contract (per rewrite)

```
MIX_BUILD_ROOT=_build-ft-<lane> MIX_ENV=test mix test test/wire/amqp_wire_test.exs \
  test/wire/egress_wire_test.exs test/runtime_contracts_test.exs \
  test/zero_drift_serialization_test.exs        # exit 0, counts recorded
MIX_BUILD_ROOT=... mix run --no-start test/e2e/s6_checkpoints/checkpoint_chain.exs -- /tmp/s6-<lane>
# RECEIPT:{"...verdict":"EXACTLY_ONCE_OK","zero_double_processing":true}  exit=0
python3 gates/test_isolation_leak_gate.py       # offender count must not regress
```

Preserved verdicts: s6 `EXACTLY_ONCE_OK` / `zero_double_processing: true`
(i21-leak-batch4 receipt); the rewrite is env-plumbing only — the CAS chain,
ports, receipt schema, and exit-code contract are untouched.

## D2. `s9_lro_chain` — replace inline substrate boot/poll with shared harness lib

`test/e2e/s9_lro_chain/run.sh` (and near-clones s4/s5/s8/s10) each carry
their own port-busy probe, DEADLINE loop, cleanup trap, and
`kill -9 $(lsof -tiTCP:...)` cleanup. Consolidation target:
`test/e2e/lib.sh` (new, sourced by run.sh scripts):

```bash
# test/e2e/lib.sh
e2e_wait_port() {  # e2e_wait_port <port> <sub_pid> <deadline_secs> <log>
  local deadline=$((SECONDS + $3))
  while ! nc -z -w1 127.0.0.1 "$1" 2>/dev/null; do
    kill -0 "$2" 2>/dev/null || { echo "substrate died; tail:" >&2; tail -40 "$4" >&2; exit 2; }
    [ $SECONDS -ge $deadline ] && { echo "port $1 not open in $3s" >&2; exit 2; }
    sleep 1
  done
}
e2e_cleanup() { ... kill subshell + lsof-listener kill, shared trap body ... }
```

(Note the `2>/dye/dev/null` typo above is a drafting artifact — correct to
`2>/dev/null`.)

- s9 keeps its own MODE detection (default vs isolated 19443) — that branch
  is s9-specific and receipt-bearing (exit 0/1/2/3 contract documented in
  its header). Only the poll loop, cleanup trap, and log-tail-on-death are
  shared.
- `lro_chain.test.mjs` L122 poll loop (`setTimeout(POLL_INTERVAL_MS)`) is
  already a bounded poll with a deadline — no fixed wait to remove; leave
  as-is.

## D3. Fixed-wait sweep across e2e run.sh scripts (audit result)

All waits in `test/e2e/*/run.sh` are bounded polls on real conditions
(port open, process alive, HTTP accepts) — no unconditional fixed sleeps
found in the wait paths. The only fixed `sleep 1` (s8 L43, s2 L76,
s9 inline) are pre-flight settle sleeps before a poll loop begins; each
could drop the sleep and enter the poll immediately (the poll's first
`nc` check would fail and retry), or keep them — not load-bearing.
Recommendation: **keep** — sub-second settle sleeps ahead of a bounded
poll are not flake channels, and touching 3 harnesses for zero measured
gain violates ERRC (delete/tighten outranks generate, but nothing here is
defective). Recorded as an audit-negative, not a GAP.

s10 L93 `sleep 0.2` and s4 L79 `sleep 0.3` sit inside existing poll loops
as poll-interval, same verdict.

## D4. Wire-tier consolidation (beyond env snapshot)

`egress_wire_test.exs` and `amqp_wire_test.exs` each carry identical
private copies of:

- `stop_existing_tree/0` — dup of `SmaltTest.Lifecycle.stop_shared_tree/0`
  plus a nil-supervisor fallback stopping Store/AmqpBroker children; the
  fallback clause is the only non-Lifecycle behavior — **move the whole
  function into `SmaltTest.Lifecycle` as
  `stop_shared_tree_with_children/0`** and delete both private copies.
- `wait_until_gone/2` — verbatim dup of Lifecycle's private `wait_gone/2`
  (100 × 10ms). Make Lifecycle export `wait_gone/2` (rename to public
  `await_gone/2`) and delete the two private copies. (eventgrid_conformance
  + metadata_endpoints also carry copies — same fix, out of this lease if
  lease is wire-only.)
- `get_free_port/0` — duplicated in 10+ files (census: eventgrid_topics_arm,
  eventgrid_conformance, wire_tier_refusal_sweep, egress_dispatch,
  amqp_wire, egress_wire, arm_wire, amqp/flow_credit, compliance/c7_events,
  compliance/c5_servicebus). Move into `SmaltTest.PortEnv.free_port/0`.
  Note: `SmaltTest.Lifecycle`'s `@shifted` already embeds the same probe —
  optional follow-up (out of lease): Lifecycle may call PortEnv internally.

## D5. Explicit non-goals

- s6 CAS chain body, receipt schema, `EXACTLY_ONCE_OK` verdict logic:
  untouched.
- s9 exit-code contract 0/1/2/3: untouched.
- s2/s8 `Process.sleep(:infinity)` substrate holds: required by design
  (foreground substrate hold in a backgrounded subshell).
- Do not regenerate any generated artifact; docs-dod-check unaffected
  (drafts dir is not a receipt path).
