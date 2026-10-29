# ja-r2 — Apim supervision fix + atom_bridge ETS migration (2026-10-21)

**Standing:** **ALIVE** — compile green, 21/21 tests passing on the touched surfaces.
Context: solo

Closes JA-1 finding #1 (HIGH, unsupervised naked `spawn_link` owner) + its
sub-item #6, and JA-4's two apim.ex findings and the atom_bridge.ex:127
hot-`persistent_term` finding.

## Fix 1 — `lib/smalt/apim.ex`: GenServer owner

`start_link/1` was `spawn_link(fn -> set_label; ensure_table; persistent_term.put;
Process.sleep(:infinity) end)`. Now:

- `use`-less `GenServer` with `init/1` doing `Process.set_label`, `ensure_table()`,
  and the same `:persistent_term.put({__MODULE__, :rate_table_owner}, self())`
  (key RETAINED: it IS read — `test/internal/impl6_process_label_test.exs:145`
  asserts on it; removing would break that test, so per instruction it is reported
  not removed).
- `start_link/1` = `GenServer.start_link(__MODULE__, :ok, name: __MODULE__)`
  (bare-atom name; a concurrent lane's disclosed JA-10 compile-unblock changed
  my in-flight `{:local, __MODULE__}` to the bare atom — identical semantics).
- `handle_info/2` passthrough. No sleeps anywhere in the module.
- `child_spec/1` unchanged (same id `Smalt.Apim`, `start_link/0` arity shim kept);
  `lib/smalt/application.ex` needed NO edit — the supervisor child contract is
  identical.

Also in apim.ex (JA-4): the lazy fallback `ensure_table/0` now creates the table
with `{:write_concurrency, true}` and `{:heir, Process.whereis(:init), []}`
(same shadow-table law as `lib/smalt/policy.ex:74-82`) so a lazy creator dying
cannot delete the window counters.

## Fix 2 — `:rate_table_owner` persistent_term key

Verified with grep across `lib/` + `test/`: READ at
`test/internal/impl6_process_label_test.exs:145`. **Retained**, not removed.
(`Process.set_label` retained for the same reason — asserted at :148.)

## Fix 3 — `lib/smalt/messaging/amqp/atom_bridge.ex`: ETS rate-limit window

`rate_limited_reason/1` migrated from per-key `:persistent_term.get/put` to a
public named ETS table `:smalt_amqp_atom_rl` (`:set`, `read+write_concurrency`,
heir to `Process.whereis(:init)`, ArgumentError-rescued lazy create — the
policy.ex idiom). Semantics preserved exactly: first occurrence of a reason
within 5s logs `inspect(reason)`; repeats within the window return
`"(aggregated)"`. No atom minting: the ETS key is the existing error atom
(tuple keys are gone; the table name namespaces the ledger).

## Out-of-scope disclosed edit (compile-freeze SLA)

- `test/internal/impl6_process_label_test.exs:141-156`: the test asserted a
  fresh `start_supervised({Smalt.Apim, []})` succeeds — premise rot after the
  GenServer became named (the self-booted app already holds the name;
  `:already_started`). Minimal fix: accept `{:error, {:already_started, _}}`
  and assert the label via the persistent_term-published owner pid as before.
  Disclosed here for both lanes' receipts.

## Verification (commands, exit codes, output tails)

Toolchain: asdf erlang 29.1.2 + elixir 1.20.4-otp-29; `MIX_BUILD_ROOT=_build-lane-r2`.

1. `mix compile` → **EXIT=0**. Tail (only pre-existing warning, not this lane's):
   ```
   deps/plug/lib/plug/router.ex:1492:56: Smalt.Mcp.Router.flatten_children/2
   Generated smalt app
   ```
2. `mix test test/apim_policy_test.exs test/internal/impl6_process_label_test.exs`
   (pre test fix) → EXIT=2, 9/10: `{:error, {:already_started, ...}}` at
   impl6_process_label_test.exs:144 — fixed as disclosed above.
3. `mix test test/apim_policy_test.exs test/internal/impl6_process_label_test.exs
   test/integration/t27lq_list_queues_feed_test.exs
   test/integration/kd155_delete_framing_test.exs` → **EXIT=0**:
   ```
   19:37:30.486 [info] [amqp] sb listener bound on port 60726
   .......
   Finished in 6.7 seconds (0.00s async, 6.7s sync)
   Result: 21 passed
   ```
   (covers the AMQP listener path — the sb listener boots inside the suite.)

No sleeps, no mocks. Files touched: `lib/smalt/apim.ex`,
`lib/smalt/messaging/amqp/atom_bridge.ex`,
`test/internal/impl6_process_label_test.exs` (disclosed). Lane build root
`_build-lane-r2` left for coordinator cleanup. Nothing committed.
