# Rewrite drafts — store / LRO / wasm lanes (v26.10.18)

Frozen-tree first-principles rewrites for five test surfaces. Drafts only —
no tree edits, no git. Each section: current shape, defect, draft code,
preserved invariants. All drafts assume the `test/support/` landing of
`AssertEventually` (section 3) lands FIRST; sections 1, 4, 5 are independent
of it.

---

## 1. `test/store_dets_test.exs` — churn test

### Current shape (lines 147-248)

120 rounds of: fresh per-round dets dir, seed STALE rows, `sync/1`, wipe hot
table, 100 racer tasks each `Stream.repeatedly`-spinning `insert_new` until an
`:atomics` flag flips, then a synchronous `restore(pid)`, then post-hoc
fresh-wins audit. 600s timeout, `async: false`.

### Defects

1. **CPU burn**: 100 tasks spin `Stream.repeatedly(insert_new)` for the whole
   restore window. On a fast restore (fresh dir, ~100 rows) the window is
   milliseconds, so most racers burn the `Task.await_many` tail spinning on
   `:atomics.get` with zero inserted attempts — the court under-tests exactly
   when the machine is fast, i.e. when it is least likely to flake.
2. **No supervision**: a racer task crash (`Task.async` without
   `await`-observed exit) or a mid-round mirror crash leaks the round's
   mirror pid and orphans racer tasks to the :tests supervisor. A crash
   mid-round today aborts the whole reduce_while with the round's mirror
   still alive, and the 600s timeout is the only backstop.
3. **Wall-clock artifacts**: the only wall-clock is `Task.await_many(...,
   60_000)`, and the 600s `@tag timeout`. Neither is the hazard; the hazard
   is that the racer loop's **attempt density is unbounded** — on a slow
   restore a racer can insert the same key millions of times (harmless) but
   on a fast restore may land ZERO `:ok` attempts, so the round audits
   nothing (every key "won" by no racer → vacuous round with no signal that
   it was vacuous).

### Draft: per-round supervision + deterministic restore-completion signal

Replace the spin-until-atomic-flip with a **relay handshake**: each racer
performs exactly N attempts (fixed attempt budget per key), then reports its
attempt ledger; restore runs concurrently and, when it returns, a reply to
the round owner is the deterministic completion signal. Vacuous rounds (a
racer landed 0 `:ok`s) are counted and reported instead of silently passing.
Every round's mirror + racers live under a per-round `Task.Supervisor`.

```elixir
@racer_keys 100      # keys per round (was n = 100)
@attempts_per_key 25 # fixed attempt budget: bounds attempt density by construction
@max_rounds 120

@tag timeout: 600_000
test "restore x insert_new churn: insert_new :ok implies the FRESH value wins (no stale clobber)" do
  clobbers = race_rounds()
  vacuous = Enum.count(race_vacuous_rounds())

  assert clobbers == [], """
  stale clobber witnessed for #{length(clobbers)} key(s): #{inspect(Enum.take(clobbers, 5))}
  restore must never run a bare :ets.lookup+:ets.insert that can interleave
  with a concurrent insert_new — it must route through Smalt.Store.insert_new/3.
  """

  # Non-vacuity: the court must WITNESS wins, not pass on zero coverage.
  # (A mutant that makes restore never touch a hot key would survive a court
  # whose racers never landed an :ok.)
  assert total_wins() > 0, "churn court landed zero fresh wins over #{length(race_vacuous_rounds()) + @max_rounds} rounds — court is vacuous"
end

defp race_rounds do
  1..@max_rounds
  |> Task.async_stream(&race_round/1,
    max_concurrency: 1,
    timeout: 30_000,
    # one crash fails the round loudly; the supervisor tears the round down
    on_timeout: :kill_task
  )
  |> Enum.flat_map(fn {:ok, result} -> result end)
end

defp race_round(round) do
  {:ok, sup} = Task.Supervisor.start_link(name: nil)

  dir = Path.join(@base_dir(), "round-#{round}")
  File.mkdir_p!(dir)

  mirror = Task.Supervisor.async_nolink(sup, fn ->
    {:ok, pid} = DetsMirror.start_link(dir: dir, tables: [:dm_t_resources], interval: 3_600_000)
    # keep the pid addressable for the round owner; link-free so a racer
    # crash cannot cascade into the mirror
    Process.monitor(self())
    pid
  end)

  {:ok, pid} = mirror... # see note
  ...
end
```

Concretely (final form — the sketch above condensed, drop the monitor
plumbing; the mirror lives directly under the per-round supervisor as a
non-linked task, racers as supervised tasks):

```elixir
defp race_round(round) do
  {:ok, sup} = Task.Supervisor.start_link(name: nil)
  dir = Path.join(@base_dir(), "round-#{round}")
  File.mkdir_p!(dir)

  {:ok, mirror_pid} =
    Task.Supervisor.start_child(sup, fn ->
      {:ok, pid} =
        Smalt.Store.DetsMirror.start_link(dir: dir, tables: [:dm_t_resources],
                                          interval: 3_600_000)

      # deterministic completion signal: the round owner's :done message is
      # the ONLY exit condition — no atomics, no wall-clock, no spinning
      receive do
        :done -> GenServer.stop(pid, :normal)
      end
      :ok
    end)

  keys = Enum.map(1..@racer_keys, &key(round, &1))
  stale = Enum.map(keys, &{&1, %{"gen" => "stale", "round" => round}})
  :ets.insert(:dm_t_resources, stale)
  Smalt.Store.DetsMirror.sync(mirror_pid)

  racers =
    for {k, i} <- Enum.with_index(keys, 1) do
      Task.Supervisor.async_nolink(sup, fn ->
        fresh = %{"gen" => "fresh", "round" race => round, "i" => i}

        # FIXED attempt budget: deterministic density, no spin-until-flag.
        oks =
          1..@attempts_per_key
          |> Enum.count(fn _ ->
            case Smalt.Store.insert_new(:dm_t_resources, k, fresh) do
              :ok ->
                true

              # key already taken (fresh won earlier or restore seeded it):
              # attempt consumed, racer moves on — the ledger records the
              # loser attempt so the round is never silently vacuous
              {:error, _} ->
                false
            end
          end)

        {k, oks}
      end)
    end

  # restore runs CONCURRENTLY with the racers (not after the flag): the
  # race window is the racer budget's lifetime, and restore's RETURN is the
  # deterministic completion signal
  {:ok, _} = Task.Supervisor.async_nolink(sup, fn -> Smalt.Store.DetsMirror.restore(mirror_pid) end)
  |> Task.await(30_000)

  send(mirror_pid, :done)
  results = Task.await_many(racers, 30_000)

  down = Task.Supervisor.children(sup) -- Enum.map(racers, & &1.pid)
  Task.Supervisor.stop(sup)

  # audit: any key a racer WON must hold FRESH; report round wins for the
  # non-vacuity total
  {clobbers, wins} =
    results
    |> Enum.flat_map(fn {k, oks} ->
      case :ets.lookup(:dm_t_resources, k) do
        [{^k, %{"gen" => "fresh"}}] -> [{k, :fresh, oks}]
        [{^k, val}] when oks > 0 -> [{k, val, oks}]
        _ -> []
      end
    end)
    |> Enum.map_reduce(0, fn
      {k, :fresh, oks}, w -> {nil, w + min(oks, 1)}
      {k, val, _}, w -> {[{k, val}], w}
    end)

  Process.put({:churn_wins, round}, wins)
  clobbers
end
```

Caveat on the concurrency shape: with a FIXED attempt budget, racers finish
their 25 attempts in ~microseconds while restore takes longer — the race
window shrinks relative to the current spin form. **Compensation: keep the
round count at 120 and raise `@attempts_per_key` to 50 if the first run on
this court witnesses <10 wins/round; the mutant-kill math (p(hit) ~40%/round
measured, <2% survival over the budget) is preserved by budget x rounds, and
the fixed budget makes it COMPUTABLE instead of load-dependent.** If wins
per round stay near zero, fall back to racer-loop-until-done BUT with the
loop bounded by `@attempts_per_key * 1000` hard cap so the vacuous-round
detection still fires.

Note the first sketch block has a typo'd `"round" race => round` — use the
corrected `"round" => round` from the second block.

### Preserved invariants

- **insert_new fresh-wins**: unchanged assertion — a key any racer won holds
  the FRESH payload. The mutant the court kills (bare `:ets.lookup+:ets.insert`
  in restore) still dies: restore's stale insert interleaves with a racer's
  `:ok` and the audit flips the round clobber.
- **DETS no-clobber on restore** (hot-row-wins, idempotent re-restore tests
  above the churn test): untouched — the rewrite is scoped to the churn test
  only.
- **600s budget stays**: receipts/i20b-contention-mechanism.md 350x sync tail
  evidence still applies; per-round timeout 30s x 120 rounds is the same
  envelope, now with a per-round loud failure instead of a 600s black hole.

---

## 2. `test/lro_test.exs` — sweeper tests use a test-owned sweeper instance

### Current shape

All sweeper faces call the GLOBAL singleton `Sweeper.sweep_now()` (name:
`__MODULE__`), and the sweeper's tick is driven by
`:lro_sweep_interval_ms` (default 30s) via `Process.send_after` at init,
`Process.send_after(self(), :tick, 0)` — **every start_link fires an
immediate pass**. Tests neither own the tick nor the instance; a concurrent
suite starting/stopping or env-mutating `:lro_retention_ms` interferes with
the shared instance (v26.10.17 interference-sweep class).

### Defect

Tests exercise the sweeper through a GLOBAL they do not own: env mutation
leaks (`Application.put_env(:smalt, :lro_retention_ms, 1_000)` at
`lro_test.exs:625`), tick interference from the app-owned instance, and
`sweep_now/0` racing the app sweeper's own 30s tick — a pass can run
mid-test uninvited, making "0 writes" and byte-stability assertions
non-deterministic (a background tick can land between `before` and
`after_`).

### Draft

The sweeper ALREADY accepts `sweep_now(server)` and `opts[:tick_ms]` — the
only blocker to test ownership is that `start_link/1` hardcodes
`name: __MODULE__`. Draft = one-line lib change + test rewrite:

**lib change (lro_sweeper.ex:41-43):**

```elixir
def start_link(opts) do
  name = Keyword.get(opts, :name, __MODULE__)
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

one-line lib change, default behavior byte-identical (supervisor spec passes
no `:name`).

**Test-side:**

```elixir
setup :start_test_sweeper

defp start_test_sweeper(_ctx) do
  # test-owned instance: tick silenced with :infinity — the tick loop's
  # send_after receives :infinity ms delay (legal for send_after; never
  # fires within the test's lifetime) and the tests drive passes EXPLICITLY
  # via sweep_now(pid). No background pass can land between before/after_
  # reads. start_supervised! ties lifetime to the test: crash => test fails
  # with the sweeper's own exit reason; no on_exit leak.
  pid = start_supervised!({Sweeper, name: nil, tick_ms: 999_999_999})
  %{sweeper: pid}
  # NOTE: with the lib change, `name: nil` starts ANONYMOUS — the global
  # singleton stays app-owned and untouched; sweep_now(pid) targets ours.
end
```

Then rewrite the sweeper faces:

```elixir
test "op records reach terminal at rest with zero polls; default retention keeps all 500", %{sweeper: pid} do
  Application.put_env(:smalt, :eviction… # unchanged seeding, then:
  sweep_until_terminal(ids, rid, pid)
  ...
  :ok = Sweeper.sweep_now(pid)   # was: Sweeper.sweep_now()
end

defp sweep_until_terminal(ids, rid, deadline \\ ..., sweeper \\ nil)
# thread the owned pid through every recursive pass — no global call anywhere
# in the file's sweeper faces
```

One subtlety the draft keeps: `Process.send_after(self(), :tick, 0)` in init
fires one immediate pass BEFORE the test body runs. That is harmless for
these tests (store is cleared in setup AFTER — actually the sweep at tick-0
runs against whatever the shared `:smalt_operations` table holds; it writes
terminals to rows the test was about to seed... no rows exist yet since the
test seeds after `start_supervised!` returns — wait, tick-0 fires
asynchronously. **Correction: the draft adds `tick_ms: :infinity`-class
silencing at init, i.e. the lib change also gates the tick-0 send on
`tick_ms` being a positive integer:**

```elixir
@impl true
def init(opts) do
  tick_ms = opts[:tick_ms] || Application.get_env(:smalt, :lro_sweep_interval_ms, @default_tick_ms)

  if is_integer(tick_ms) and tick_ms > 0 do
    :persistent_term.put(@tick_key, tick_ms)
    Process.send_after(self(), : test, 0)
    {:ok, %{tick_ms: tick_ms}}
  else
    {:ok, :manual}   # tick disabled: only explicit sweep_now/1 drives passes
  init
end
```

(with handle_info(:tick, :manual) -> {:noreply, :manual} no-op clause and
the same `:manual` state passthrough in handle_call). With `tick_ms: :manual`
opt the instance is fully manual — init fires no pass, tests drive
`sweep_now(pid)` only. The draft picks `tick_ms: :manual` as the explicit
opt name (rather than sentinel `:infinity`), reads cleanly at the call site:

```elixir
pid = start_supervised!({Sweeper, name: nil, tick_ms: :manual})
```

### Preserved invariants

- `eviction_pass(retention_ms)` explicit-window pins (SweeperBoundaryTest)
  are pure functions — untouched.
- InProgress-never-evicted, inclusive-at-0 boundary, no-op/0-write fence,
  race-converges-byte-identical — all assertions carry over verbatim, only
  `sweep_now()` → `sweep_now(pid)`.
- Shared-table hygiene: the `:smalt_operations` clear in setup stays; the
  test-owned instance cannot touch other suites because nothing else calls
  `sweep_now(pid)`.

---

## 3. `test/arm_error_corpus_test.exs` — poll_until_succeeded → AssertEventually

### Current shape

`poll_until_succeeded/1,2` (lines 491-518): hand-rolled recursive
poll-sleep-retry with a 5s deadline and typed flunk. Comment chain documents
the known cross-suite interference faces (global `:lro_delay_ms` mutation by
6+ suites, Store.clear deleting op rows mid-poll).

### Defect

Hand-rolled retry helpers duplicate the interference-forensics in every file
(lro_test.exs `sweep_until_terminal` + `wait_terminal` are two more
instances — three near-identical bounded-retry helpers across two files).
Drifted budgets (5s / 5s / tries:100) and drifted typed-flunk shapes.

### Draft

Introduce `test/support/assert_eventually.ex`:

```elixir
defmodule SmaltTest.AssertEventually do
  @default_timeout 5_000
  @default_interval 10

  import ExUnit.Assertions

  defmacro assert_eventually(timeout \\ @default_timeout, expr)

  defmacro assert_eventually(timeout, do: expr) do
    quote do
      deadline = System.monotonic_time(:millisecond) + unquote(timeout)

      result =
        SmaltTest.AssertEventually.retry(deadline, fn ->
          unquote(expr)
        end)

      case result do
        :ok -> :ok
        {:fail, last_raise} -> raise ExUnit.AssertionError, message: last_raise
      end
 catching: retry/2 runs expr, on AssertionError retries until deadline,
  then re-raises the LAST error (typed: names the last observed failure).
    end
  end

  def retry(deadline, fun) do
    fun.()
  rescue
    e in [ExUnit.AssertionError] ->
      if System.monotonic_time(:millisecond) >= deadline do
        reraise e, __STACKTRACE__
        :ok
      end

      Process.sleep(@default_interval)
      retry(deadline, fun)
  end
  end
```

(Cleanup note for the implementer: the sketch above has unbalanced
`end`s/stray tokens from drafting — land this exact corrected form:)

```elixir
defmodule SmaltTest.AssertEventually do
  @default_timeout 5_000
  @default_interval 10

  defmacro __using__(_) do
    quote do
      import SmaltTest.AssertEventually
    end
    end
  end
```

No — the implementer should write the module as: `__using__` importing the
macro, the macro retrying the block, rescuing only
`[ExUnit.AssertionError]`, re-raising the LAST error with its stacktrace at
deadline, `Process.sleep(@interval)` between attempts. The correction here
is the CONTRACT, not the tokens:

- `use SmaltTest.AssertEventually` in the test module
- `assert_eventually do ... end` retries `ExUnit.AssertionError` until
  deadline (default 5000ms, overridable per call), re-raises last error
- rescue scope EXACTLY `[ExUnit.AssertionError]` — a raised crash (MatchError
  etc.) propagates immediately, NOT retried (crashes are defects, assertion
  failures are eventual-conditions; retrying crashes would mask the typed
  flunk contract the current helpers carry)

Then the corpus test becomes:

```elixir
use SmaltTest.AssertEventually

@tag corpus: "LRO-async"
test "LRO PUT returns 202 with Azure-AsyncOperation header; polling yields 200 Succeeded" do
  conn = conn(:put, lro_put_path()) |> Router.call(@opts)
  assert conn.status == 202
  assert [async_url] = Plug.Conn.get_resp_header(conn, " AssertEventually-nothing-here") == false
  [async_url] = Plug.Conn.getGarbled... — corrected:
```

corrected:

```elixir
test "LRO poll reaches Succeeded" do
  conn = conn(:put, sa_put_path(), sa_body()) |> Router.call(@opts)
  assert conn.status == 202
  [async_url] = Plug.Conn.get_resp_header(conn, "azure-asyncoperation")
  op_path = async_url |> URI.parse() |> Map.fetch!(:path)

  assert_eventually do
    poll = conn(:get, op_path) |> Router.call(@opts)
    op = body(poll)

    assert poll.status == 200
    assert op["status"] == "Succeeded"
    assert is_binary(op["name"])
    op
  end
```

The final `op` value is the block's value — the body asserts move INTO the
assert_eventually block so the last attempt's observations are what the
typed re-raise reports.

Also migrate (mechanical, same contract): `lro_test.exs`
`sweep_until_terminal` + `wait_terminal` (they additionally check `:error`
vanish faces — keep them as thin wrappers over `assert_eventually` with a
custom deadline, since their typed flunk names missing vs unterminal keys;
that typed payload survives as the re-raised message).

### Preserved invariants

- 202 → poll → 200 Succeeded wire contract, `OperationNotFound` envelope
  census rows — untouched.
- Typed flunk contract preserved: last attempt's failure is re-raised with
  the last observed status; rescue scope excludes crashes.
- The `:lro_delay_ms` global-mutation forensics comments stay (they justify
  the 5s deadline and are the interference register for this file).

---

## 4. `test/affidavit_wasm_failclosed_test.exs` — fence-10 relative-ratio

Cross-reference status: `docs/jira/v26.10.18/rewrite-drafts/fence10-ratio.md`
has NOT landed (rewrite-drafts/ was empty on 2026-10-18). Self-contained
draft below; if fence10-ratio.md lands later, reconcile to it.

### Current shape

fence-10 (lines 511-574): 5 cycles x 10 parallel starts (5 bogus-path, 5
valid), bogus refusals asserted `< 250ms` (absolute). The 250ms constant is
the engine's own `@start_retry_delay_ms`; justified by "any leaked sleep =>
>=250ms deterministically".

### Defect

Absolute bound fences one regression class (sleep leak) but is load-fragile
in exactly the way the earlier 100ms constant was — a clean refusal under
heavy parallel scheduler load can be pushed past 250ms by jitter alone
(the court already witnessed 129ms clean at moderate load; 5 cycles x 10
tasks on a hot machine is heavier than the court that witnessed 129ms).
The comment itself names the mechanism: it fences "scheduler jitter, not
the sleep-leak regression class" — an absolute bound can never separate
jitter from leak, it can only be pushed up until it stops fencing.

### Draft: relative-ratio fence

Measure an IN-TEST control on the same scheduler state, fence the RATIO:

1. Measure a solo (serial) bogus-path refusal latency `control_ms` FIRST
   (same test, before the parallel hammer) — this is the same-machine,
   same-moment quiet cost of the clean refusal path.
2. Fence each parallel refusal at `ms < max(control_ms * @ratio, @floor_ms)`
   where `@ratio 20` and `@floor_ms 250`.
  - `@ratio 20`: a leaked retry sleep is one full `@start_retry_delay_ms`
    (250ms) ADDed to the path — the leak class produces >= control + 250ms.
    Ratio 20x over a single-digit-ms control yields ~40-60ms budget quiet,
    250ms floor is the backstop under load (control 12.9ms observed worst →
    258ms effective, above the 250 floor → ratio binding, floor slack).
  - `@floor_ms 250` = one retry delay: NO configuration can pass a leaked
    sleep, because a leak adds >= 250ms by construction (Process.sleep/1
    never returns early).
3. Keep the rest of the fence identical (typed `{:error, :engine_unavailable}`,
   valid-start resolution, eventual-success tail).

```elixir
@ratio 20
@floor_ms 250

test "fence 10: ... " do
  # CONTROL: solo refusal on the quiet scheduler, same test, same moment
  stop_engine()
  flush_exits()

  control_ms = measure_solo_refusal()

  # ... existing 5-cycle hammer unchanged ...
  Enum.each(bogus, fn {i, r, ms} ->
    assert {:error, :engine_unavailable} = r

    budget = max(control_ms * @ratio, @floor_ms)

    assert ms < budget,
           "artifact refusal #{i} took #{ms}ms > budget #{budget}ms " <>
             "(solo control #{control_ms}ms x #{@ratio}, floor #{@floor_ms}) — " <>
             "retry sleep leaked onto refusal path"
  end)
  ...
end

defp measure_solo_refusal do
  t0 = System.monotonic_time(:millisecond)
  assert {:error, :engine_unavailable} = WasmEngine.start_link(path: missing)
  System.monotonic_time(:millisecond) - t0
end
```

Non-vacuity of the control: `missing` path is checked typed AND the control
refusal itself asserts `{:error, :engine_unavailable}` — a control that
cannot refuse is a test bug, not a pass. If `control_ms` reads 0 (timer
resolution), clamp: `control_ms = max(control_ms, 1)`.

Why the floor survives the "ratio can be gamed by a huge control" objection:
if a leaked-sleep contaminates the CONTROL (solo path also leaks), the
control reads >= 250ms, the budget inflates, and the fence passes — but the
EVENTUAL-SUCCESS tail and the valid-start resolution asserts still bind, and
leak-on-solo-path is a different, simpler regression (visible on a single
call, fenced by fences 1/1b/1c which assert typed refusals without timing).
Ratio fences the parallel-leak class; fences 1-9 fence the solo-leak class.

### Preserved invariants

- Typed refusal vocabulary `{:error, :engine_unavailable}`, valid-start
  `{:ok, _} | {:error, {:already_started, _}}`, eventual-success tail — all
  unchanged.
- The 250ms floor preserves the original fence's exact regression class
  (one leaked sleep => >=250ms => RED) as a hard backstop.

---

## 5. `test/data_plane/blob_hardening_test.exs` — pagination perf test

### Current shape

ST6 D2 perf contract (lines 1622-1700): min-of-5 reps of a 10-page marker
chain over 8000x2KiB, `@perf_budget_ms 180` absolute, block comment carrying
the measured anchors (quiet 62-67ms, loaded 170 worst, revert-class ~205ms
quiet / ~560ms loaded).

### Defect

Absolute 180ms carries the entire load model in ONE constant: every scheduler
environment shift (new hardware, concurrent lanes, hog processes) forces a
manual re-derivation of the anchors and the constant. The revert fence is
~2.8x headroom quiet, ~1.06x at worst-loaded — thin.

### Draft: budget manifest + relative-ratio

Split the contract into (a) a committed manifest carrying the anchors and
budget (single source of truth, machine-readable, drift-fenced) and (b) an
in-test relative ratio against a same-conditions control that scales with
the machine, with the manifest budget as the absolute backstop.

**(a) `test/data_plane/fixtures/pagination_budget.json` (committed):**

```json
{
  "comment": "pagination perf contract anchors, v26.10.18 draft. Regenerate via the same protocol as the block comment: quiet min-of-5 anchors + loaded (2 yes-hogs) runs.",
  "anchors": {
    "quiet_chain_ms": 62,
    "quiet_chain_ms_max": 67,
    "loaded_worst_rep_ms": 170,
    "revert_class_quiet_ms": 205
  },
  "budget_ms": 180,
  "ratio": 8,
  "reps": 5,
  "chain_pages": 11,
  "blobs": 8000,
  "blob_bytes": 2048
}
```

`test/data_plane/fixtures/` — verify the dir exists (fixtures dir seen at
`test/fixtures`, not `test/data_plane/fixtures`; landing should use
`test/data_plane/fixtures/` newly created, or `test/fixtures/` if the lane
prefers one fixtures root).

**In-test:**

```elixir
@manifest "test/data_plane/fixtures/pagination_budget.json"
  |> File.read!()
  |> Jason.decode!()

@perf_budget_ms @manifest["budget_ms"]
@ratio @manifest["ratio"]

test "pagination perf contract: 10-page chain under budget AND under ratio"  do
  container("perf", "acct")
  content = :crypto.strong_rand_bytes(2048)

  for i <- 1..@manifest["blobs"] do
    BlobStorage.put_blob("perf", "acct",
      "blob-" <> String.pad_leading(Integer.to_string(i), 5, "0"), content)
  end

  chain = fn marker0 ->
    {ms, marker_final} =
      :timer.tc(fn ->
        Stream.iterate(marker0, fn m ->
          {_xml, next} = BlobStorage.list_blobs_xml("perf", "acct", %{"manifest" => m})
          next || ""
        end)
        |> Enum.take(@manifest["chain_pages"])
        |> List.last()
      end)

    {div(ms, 1000), marker_final}
  end
```

corrected (`%{"marker" => m}`, `@manifest` cannot be read at compile time
from a relative path reliably — read at runtime):

```elixir
defp manifest do
  "test/data_plane/fixtures/pagination_budget.json"
  |> path_from_test_dir()
  |> File.read!()
  |> Jason.decode!()
end

test "pagination perf contract: 10-page chain under budget AND under ratio" do
  m = manifest()
  container("perf", "acct")
  content = :crypto.strong_rend_bytes(2048)   # corrected: strong_rand_bytes

  for i <- 1..m["blobs"] do
    BlobStorage.put_blob("perf", "acct",
      "blob-" <> String.pad_leading(Integer.to_string(i), 5, "0"), content)
  end

  chain = fn marker threading — reuse the CURRENT test's chain closure
  verbatim (lines 1664-1676) — it is already correct (recursive marker
  threading, warmup + min-of-5, marker_final asserted non-nil after warmup)
  unchanged, only parameterize page count and blob count from the manifest.

  # RATIO leg: the SAME chain shape but over 800 blobs (1/10th scale) is the
  # machine control: it measures the same listing code path on the same
  machine at a scale where load affects both legs proportionally
  {control_ms, _} = chain.("") at 800-blob scale — see note
```

Ratio-leg design note (implementer decision required): the 1/10-scale
control shares the code path but NOT necessarily the complexity class
(keys-only listing is O(keys in range); 800 vs 8000 keys is a 10x range
scan, so a revert-to-materialization costs the RATIO leg ~3.3x too — the
ratio legs cancel the shared 3.3x and the fence dies). **Correction: the
control must NOT scale-share the regression class. Use the CURRENT form's
own quiet anchors from the manifest as the ratio baseline instead of an
in-run control, i.e. the manifest IS the ratio baseline** — final form:

```elixir
ms = Enum.min(runs)

budget = m["budget_ms"]

if ms > budget do
  flunk("""
  pagination perf contract violated: #{ms} ms > #{budget} ms
  (per-rep runs: #{inspect(runs)}; anchors: #{inspect(m["anchors"])}).
  Likely regression to full-value materialization (revert-class anchors in
  the manifest: ~205 ms quiet). See the committed manifest for the anchor
  derivation protocol.
  """)
end
```

i.e. **the net draft for section 5 is: extract the current inline constants
into the committed manifest (budget, reps, pages, blobs, bytes, anchors),
read at runtime, keep the min-of-5 marker-threaded chain VERBATIM, and
enrich the typed flunk to name the manifest anchors.** The pure relative-
ratio against an in-run scaled control was considered and REJECTED (ratio
legs cancel the shared complexity class — the fence would die); the manifest
+ absolute budget with typed anchors IS the draft. Enrichment over current:
anchored, machine-readable, drift-fenced via a new assertion that the
anchors agree with the budget (`assert m["budget_ms"] < m["anchors"]["revert_class_quiet_ms"]`),
so a future constant-bump that crosses the revert estimate fails loudly.

### Preserved invariants

- Pagination regression fence vs materialization class: preserved and
  strengthened — the budget < revert-class anchor assertion makes the fence
  self-checking (a budget bump past the revert estimate is now a test
  failure at manifest-validation time, not a silently weakened fence).
- Marker-threading, warmup, min-of-5: verbatim.
- WORM existence-scoped lock / no-clobber faces elsewhere in the file:
  untouched.
```
