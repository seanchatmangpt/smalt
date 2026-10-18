# ERRC-Eliminate: fixed `Process.sleep` inventory — test/

Read-only inventory (court-attempt-5 freeze; no test edits, no git). Method:
`grep -rn "Process.sleep" test/` → **107 hits**, each classified with surrounding
context read from disk. Result: **78 compliant, 29 fixed sites in 15 files.**

- **Compliant (no action)**: sleep inside a bounded-retry/poll loop
  (`wait_until`, `wait_gone`, `wait_for_gone`, `resilient_clear`,
  `poll_until_terminal`, `sweep_until_terminal`, `connect_with_heal`,
  `retry_5xx`, `boot_with_retry`, `await_dead`, `consume`,
  `port_verdict_agrees?`, `wait_for_ephemeral_port`, `wait_listener`,
  shacl_fuzz snapshot backoff); `Process.sleep(:infinity)` parks
  (mcp_test.exs:929, affidavit_ingestion_functor_test.exs:226,
  egress_dispatch_test.exs:1874/2004, audit_planes 1499–1587,
  redteam/e2e run.sh harnesses); pacing `sleep(1)`/`sleep(2)` inside
  deliberate hammer/walk loops (mcp_test.exs:1279, audit_planes 423/650,
  enclave_doctor_severity 74, pplan 534/1128/1243/2489, lro 822,
  crash_isolation 154).

Fixed-site classes:
- **A (poll-replaceable sync-wait): 12 sites** — replace with `eventually/2`.
- **B1 (inherent time-advance): 13 sites** — the sleep crosses a real time
  window (rate-limit second boundary, lock expiry, LRO retention). No poll
  replacement exists; keep, parameterize, name the budget.
- **B2 (absence-check settle): 4 sites** — the assertion is that NOTHING
  happened; replace with `eventually_stays/3` (stability window), not a bare sleep.

## Proposed shared helper (does not exist yet)

`SmaltTest.AssertEventually` — draft `test/support/assert_eventually.ex`:

```elixir
defmodule SmaltTest.AssertEventually do
  @moduledoc """
  eventually/2 polls fun/0 every :interval_ms until it returns a truthy value
  (-> {:ok, value}) or :deadline_ms elapses (typed flunk carrying the LAST
  observation, never a bare timeout).

  eventually_stays/3 polls fun/0 until it has held truthy CONTINUOUSLY for
  :stability_ms (absence/quiescence checks: the bad thing must NOT appear).
  """

  import ExUnit.Assertions

  @default_deadline_ms 5_000
  @poll_interval_ms 10

  @spec eventually((-> term), keyword) :: {:ok, term} | no_return
  def eventually(fun, opts \\ []) when is_function(fun, 1) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    interval = Keyword.get(opts, :interval_ms, @poll_interval_ms)
    desc = Keyword.get(opts, :desc, "condition")
    do_poll(fun, deadline, interval, desc, nil)
  end

  @spec eventually_stays((-> term), keyword) :: :ok | no_return
  def eventually_stays(fun, opts \\ []) when is_function(fun, 1) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :within_ms, @default_deadline_ms)

    stability_ms = Keyword.get(opts, :stability_ms, 50)
    interval = Keyword.get(opts, :interval_ms, @poll_interval_ms)
    desc = Keyword.get(opts, :desc, "condition")

    stable(fun, deadline, stability_ms, interval, desc, nil, nil)
  end

  # eventually/2 core
  defp do_poll(fun, deadline, interval, desc, _last) do
    case safe(fun) do
      {true, value} ->
        {:ok, value}

      {false, value} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually(#{desc}) timed out; last observation: #{inspect(value)}")
        end

        Process.sleep(interval)
        do_poll(fun, deadline, interval, desc, value)
    end
  end

  # eventually_stays/3 core: condition must hold continuously for stability_ms
  defp stable(fun, deadline, stability_ms, interval, desc, stable_since, last) do
    now = System.monotonic_time(:millisecond)

    cond do
      stable_since != nil and now - stable_since >= stability_ms ->
        :ok

      now >= deadline ->
        flunk(
          "eventually_stays(#{desc}) never held stable for #{stability_ms}ms " <>
            "within deadline; last observation: #{inspect(last)}"
        )

      true ->
        case safe(fun) do
          {true, value} ->
            since =
              if stable_since == nil,
                do: now,
                else: stable_since

            Process.sleep(interval)
            stable(fun, deadline, stability_ms, interval, desc, since, value)

          {false, value} ->
            Process.sleep(interval)
            stable(fun, deadline, stability_ms, interval, desc, nil, value)
        end
    end
  end

  defp safe(fun) do
    v = fun.()
    {truthy?(v), v}
  catch
    kind, reason -> {false, {:raise, kind, reason}}
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true
end
```

Contract notes:

- fun/0 returns any term; `nil`/`false` keep polling; anything else is truthy.
- Exceptions inside fun/0 are captured as observations (the commonest poll body
  is `{:ok, rec} = Store.get(...)` which raises MatchError while a record is
  still InProgress); the last exception rides the typed flunk.
- Typed flunk carries `desc` + LAST observation — a timeout reports what the
  subject was actually doing, not just that it wasn't.
- `eventually/2` replaces wait-for-something; `eventually_stays/3` replaces
  sleep-then-assert-absence (B2). Existing per-file `wait_until` helpers keep
  working; migration is per-site, no big-bang.
- All drafts below call it fully qualified: `SmaltTest.AssertEventually.eventually(...)`.

## A. Fixed sync-wait sites — 12 drafts

### A1. test/lro_test.exs — LRO terminality (4 sites)

All wait `lro_delay_ms + epsilon` for op terminality, then hard-assert. Suite
pins `lro_delay_ms = 20` in setup (lro_test.exs:35), so `deadline_ms: 5_000` is
huge headroom and the epsilon adders (+5/+10/+40) are scheduler-jitter lottery
tickets. Observable: `Smalt.Store.get(:smalt_operations, id)` →
`%{"status" => "Succeeded"}`.

**lro_test.exs:144** — `Process.sleep(delay + 10)` before single wire poll →

```elixir
delay = Application.get_env(:smalt, :lro_delay_ms, 0)

assert {:ok, _} =
         SmaltTest.AssertEventually.eventually(
           fn ->
             match?({:ok, %{"status" => "Succeeded"}}, Smalt.Store.get(:smalt_operations, id))
           end,
           deadline_ms: 5_000,
           desc: "LRO op #{id} terminal in store"
         )

# existing wire poll + asserts unchanged below
poll = conn(:get, op_path) |> call()
```

**lro_test.exs:338** — `sleep(lro_delay_ms + 40)` before ONE wire GET of the
delete-operation location URL →

```elixir
assert {:ok, _} =
         SmaltTest.AssertEventually.eventually(
           fn ->
             poll = conn(:get, URI.parse(loc).path) |> call()

             match?(
               {200, %{"status" => "Succeeded"}},
               {poll.status, Jason.decode!(poll.resp_body)}
             )
           end,
           deadline_ms: 5_000,
           desc: "delete LRO terminal at #{loc}"
         )

poll = conn(:get, URI.parse(loc).path) |> call()
assert poll.status == 200
assert %{"status" => "Succeeded"} = Jason.decode!(poll.resp_body)
```

**lro_test.exs:402** — `sleep(delay + 5)` before the 10-concurrent-poller
fan-out. Replace the sleep with the same store-level eventually as :144
(closure over `id`), then run the fan-out unchanged.

**lro_test.exs:1147** — `Process.sleep(60)` before the 24-concurrent-poller
fan-out. Same replacement: store-level eventually on
`Store.get(:smalt_operations, id)` reaching `%{"status" => "Succeeded"}`,
then the fan-out unchanged.

### A2. test/smalt_ets_composite_identity_test.exs:245 and test/smalt_ets_baseline_identity_test.exs:106

`Process.sleep(10)` then `Sweeper.eviction_pass()` then strict
`snapshot() == baseline` identity fence. The sleep gambles that in-flight LRO
activity has settled. Observable: post-eviction snapshot converges to baseline.

```elixir
assert {:ok, _} =
         SmaltTest.AssertEventually.eventually(
           fn ->
             :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass()
             snapshot() == baseline
           end,
           deadline_ms: 5_000,
           desc: "post-eviction store snapshot converged to baseline"
         )
```

Identical replacement at both sites (identical pattern).

### A3. test/store_dets_test.exs:35 — DetsMirror flush

`Process.sleep(150)` waits past one 50 ms mirror tick + epsilon before the
closed dets read. Observable: the row is in the dets file. dets named tables
are node-unique, so the probe uses a fresh table name per attempt.

```elixir
assert {:ok, _} =
         SmaltTest.AssertEventually.eventually(
           fn ->
             probe = String.to_atom("probe_res_#{System.unique_integer([:positive])}")

             with {:ok, res} <-
                    :dets.open_file(probe,
                      file: ~c"#{dir}/dm_t_resources.dets",
                      repair: false
                    ),
                  rows when is_list(rows) <- :dets.match_object(res, :_) do
               :dets.close(res)
               Enum.any?(rows, &match?({"/r/a", %{"name" => "a"}}, &1))
             else
               _ -> false
             end
           end,
           deadline_ms: 5_000,
           desc: "DetsMirror flushed row /r/a to dm_t_resources.dets"
         )

# then the final closed reads + asserts (existing code, unchanged)
```

(Same treatment for the `:dm_t_docs` row if its read is also post-sleep.)

### A4. test/tls_test.exs:474 — trace-mailbox drain

`Process.sleep(200)` lets in-flight trace events land in the tracer mailbox
before requesting the log. Observable: tracer round-trip reports the expected
op count. `expected` = the traced call count the test already knows.

```elixir
{:ok, ops} =
  SmaltTest.AssertEventually.eventually(
    fn ->
      send(tracer, {:ops, self()})

      receive do
        {:ops, ops} -> if length(ops) == expected, do: ops, else: false
      after
        0 -> false
      end
    end,
    deadline_ms: 5_000,
    desc: "tracer mailbox drained to #{expected} ops"
  )
```

### A5. test/affidavit_wasm_failclosed_test.exs:42 and :71 — NIF teardown settle

Both are settle sleeps after `wait_until(whereis(WasmEngine) == nil)` —
"wasmtime store/instance teardown is asynchronous behind the NIF; an immediate
re-start races it". The real observable is that a restart SUCCEEDS, not that
25 ms elapsed. Bounded start-retry on the typed failure:

```elixir
defp typed_start(opts, n \\ 20)

defp typed_start(_opts, 0),
  do: flunk("wasm engine restart never succeeded (NIF teardown drain) within 20 retries")

defp typed_start(opts, n) do
  if pid = Process.whereis(WasmEngine) do
    GenServer.stop(pid, :normal)
    wait_until(fn -> is_nil(Process.whereis(WasmEngine)) end)
  end

  case WasmEngine.start_link(opts) do
    {:error, :engine_start_failed} -> typed_start(opts, n - 1)
    {:error, {:already_started, pid}} ->
      GenServer.stop(pid, :normal)
      wait_until(fn -> is_nil(Process.whereis(WasmEngine)) end)
      typed_start(opts, n - 1)

    other ->
      other
  end
end
```

Covers both :42 (`stop_engine` path) and :71 (duplicate-start fence path).

### A6. test/security/security_hardening_test.exs:1115 — monitor Down propagation

`Process.sleep(10)` after `Process.exit(pid, :kill)` "lets the monitor Down
propagate before the next append". Observable: the LedgerWriter process was
replaced (supervisor restart) — poll whereis, then append.

```elixir
killed = pid

assert {:ok, _} =
         SmaltTest.AssertEventually.eventually(
           fn ->
             case GenServer.whereis(Smalt.Security.LedgerWriter) do
               ^killed -> false
               new when is_pid(new) -> new
               _ -> false
             end
           end,
           deadline_ms: 5_000,
           desc: "LedgerWriter restarted after kill"
         )

assert {:ok, %{"transactionId" => "2.1", ...}} = ConfidentialLedger.append_transaction(...)
```

### A7. test/enclave-testbed/enclave_testbed.exs:835 — LRO terminality post-restart

`Process.sleep(30)` (with `lro_delay_ms = 1`) before `Sweeper.sweep_now()` and
the terminal assert. Same shape as A1: poll `LRO.get_op(rec["name"])` for
`%{"status" => "Succeeded"}` after the sweep, deadline 5_000.

## B1. Inherent time-advance — 13 sites, keep + parameterize

The sleep crosses a REAL time window; no observable can be polled because the
condition under test is time itself. Keep, but (a) name the window, (b) derive
the sleep from the configured constant, never a literal epsilon.

| site | window crossed |
|---|---|
| test/lro_test.exs:651, :701, :734 | LRO delay elapse before `sweep_now()` (eviction/no-rewrite/race windows) |
| test/lro_test.exs:672 | delay elapse to prove still-InProgress (no lazy terminalization — negative, see B2 note) |
| test/mcp_wire_test.exs:956 | idle gap (keep-alive survival) — 1500 ms literal; parameterize via env |
| test/compliance/c1_arm.exs:399, :422 | wall-clock 1 s fixed-window alignment + rollover |
| test/smalt_arm_gateway_test.exs:1287 | second-boundary alignment (`wait_for_fresh_window`) |
| test/arm_error_corpus_test.exs:477 | second-boundary alignment (`wait_for_fresh_window`) |
| test/amqp/queue_store_test.exs:607, :611 | lock original(+1000)-vs-renewed(+1700) expiry choreography |
| test/amqp/sweeper_test.exs:87 | 1 ms `amqp_sweeper_lock_grace_ms` elapse |
| test/enclave-testbed/enclave_testbed.exs:610 | LRO deadline elapse before at-rest sweep |

Note on lro:672: it asserts InProgress SURVIVES past the delay (absence of
terminalization). It is honest as a time-advance + negative assert; do not
convert to `eventually` (that would invert the law). A `eventually_stays` on
`status == "InProgress"` for the window duration is the only tightening.

## B2. Absence-check settle — 4 sites, use `eventually_stays/3`

Sleep-then-assert-nothing-happened. `eventually/2` cannot prove absence
(first poll is trivially true); the correct shape is a stability window.

**test/amqp/r129_session_gate_test.exs:166** (after error close) and **:296**
(after cleanup detach):

```elixir
:ok =
  SmaltTest.AssertEventually.eventually_stays(
    fn -> 0 == count_state(queue <> "/", :any) and 0 == count_state(queue, :any) end,
    within_ms: 5_000,
    stability_ms: 50,
    desc: "no shadow-namespace state lands after session-gate close"
  )
```

**test/amqp/broker_facade_test.exs:63** (listener healthy across client
disconnects) and **:96** (listener + ConnSup survive a killed connection):

```elixir
:ok =
  SmaltTest.AssertEventually.eventually_stays(
    fn -> Process.alive?(pid) end,
    within_ms: 5_000,
    stability_ms: 50,
    desc: "listener survives client churn (no delayed crash)"
  )

# :96 additionally: Process.alive?(Process.whereis(Smalt.AmqpBroker.ConnSup))
# inside the same closure, plus the fresh-connect probe stays outside the window.
```

Budget equivalence: the stability window equals the retired sleep's budget
(50 ms), but the failure is now typed and the pass is window-verified rather
than elapsed-time-verified.

## C. Compliant sites (78) — enumerated by pattern

Retry-loop idiom (sleep inside bounded until/poll): telemetry_test.exs:265,
smalt_affidavit_wasm_test.exs:121, affidavit_ingestion_functor_test.exs:264,
admission_projection_test.exs:416/:460, eventgrid_conformance_test.exs:501,
metadata_endpoints_test.exs:376, wire/egress_wire_test.exs:1040,
wire/amqp_wire_test.exs:153, test_helper.exs:95/:151/:198,
mcp_wire_test.exs:566/:881, pplan_test.exs:55/:1113,
kv_tls_test.exs:124/:208/:368, chaos/crash_isolation_test.exs:51/:64/:135/:137,
chaos/port_collision_test.exs:154, lro_test.exs:180/:1207,
compliance/c1_arm.exs:672/:820, compliance/c3_cosmos.exs:1050,
compliance/c4_blob.exs:1518, compliance/c2_keyvault.exs:115,
data_plane/cosmos_test.exs:2313, smalt_arm_gateway_test.exs:667,
smalt_ets_composite_identity_test.exs:358, enclave_testbed.exs:772/:850,
arm_error_corpus_test.exs:512, enclave_doctor_severity_test.exs:74 (pacing),
shacl_fuzz.exs:525/:533/:541 (backoff).

`:infinity` parks (process fixtures): mcp_test.exs:929,
affidavit_ingestion_functor_test.exs:226, egress_dispatch_test.exs:1874/:2004,
audit_planes_test.exs:1499/:1521/:1551/:1587, sdk-smoke/run.mjs:148 (string),
redteam/r3_amqp/run.sh:106, e2e/s2_byok/run.sh:50, e2e/s8_cosmos_race/run.sh:53.

Pacing inside deliberate loops: mcp_test.exs:1279, pplan_test.exs:534/:1128/:1243/:2489,
audit_planes_test.exs:423/:650, lro_test.exs:822, crash_isolation_test.exs:154.
