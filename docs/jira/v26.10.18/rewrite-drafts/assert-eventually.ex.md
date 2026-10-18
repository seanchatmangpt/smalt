# Draft: `test/support/assert_eventually.ex` — `SmaltTest.AssertEventually`

Status: DRAFT (frozen tree; no edits, no git)
Window: v26.10.18
Collapses four proven per-suite helpers onto one bounded-poll primitive:

| Instance | Site | Pattern |
|---|---|---|
| i21 `sweep_until_terminal/3` | test/lro_test.exs:1181 | set-membership poll + interleaved driver |
| i22 `poll_until_succeeded/2` | test/arm_error_corpus_test.exs:493 | HTTP poll, typed immediate-fail arm |
| i22 `resilient_clear/0,1` | test/corpus/helper.exs:38; c3_cosmos.exs:1038; c4_blob.exs:1506 | exception-retry (dead-table ArgumentError) |
| resilient seed pattern `resilient_clear(post_seed)` | test/compliance/c1_arm.exs:807 | exception-retry + seed inside the rescue window |

## Contract

- `fun/0` returns `{:ok, value}` → success; `eventually/2` returns `value` (not `:ok`) so callers assert on the terminal observation instead of re-reading it.
- `fun/0` returns `:retry` | `{:retry, detail}` → poll again after backoff; `detail` becomes the *last value* in the flunk.
- Any other return fails immediately with a typed message naming the observable and the offending return — generalizes `poll_until_succeeded`'s "unexpected poll status" arm.
- `retry_on: {ExceptionType, exact_message}` retries only that exact exception (i22 dead-table `ArgumentError` pattern; exact-message match, everything else `reraise`d with stacktrace).
- Deadline-bounded via `System.monotonic_time(:millisecond)`, default 5000 ms — same budget as `@poll_deadline_ms` in arm_error_corpus. Deadline-bounded is the law: an attempt count does not measure time under load (the i22 50-attempt bound was a proxy for "~500 ms of recovery"; the wall-clock form is strictly stronger).
- Backoff: start `backoff_ms` (default 10, the i22 constant), double per pass, cap `max_backoff` (default 200). Sleep is clamped to the remaining deadline.
- On-exit-safe: monotonic clock + `Process.sleep/1` only. No named processes, no process dictionary, no app-tree ownership; safe from `setup`, `on_exit`, or the test process. `flunk/1` raises a normal `ExUnit.AssertionError` — no test-process binding.
- Flunk message names: observable (opt `:observable`), deadline, pass count, last value — mirrors the i21/i22 messages ("missing=... unterminal=...", "last_status=...").

## Module source (draft of record)

```elixir
defmodule SmaltTest.AssertEventually do
  @moduledoc """
  Shared bounded-poll helper (v26.10.18): collapses the four proven per-suite
  retry helpers onto one primitive.

  Contract:

    - `fun` returns `{:ok, value}` -> success; `eventually/2` returns `value`
    - `fun` returns `:retry` | `{:retry, detail}` -> poll again after backoff
    - anything else -> immediate typed failure naming the observable and the
      offending return
    - `retry_on: {ExceptionType, exact_message}` retries that exact exception;
      every other exception propagates immediately via reraise

  Chicago discipline: `fun` observes real state, no mocks. On-exit-safe:
  monotonic clock + `Process.sleep/1` only — owns no processes, no process
  dictionary; safe from `setup`, `on_exit`, or the test process.

  ## Examples

      iex> eventually(fn -> {:ok, :ready} end, observable: "app ready")
      :ready

      iex> eventually(fn -> :ok end, observable: "wrong shape")
      ** (ExUnit.AssertionError) eventually: fun returned :ok — expected {:ok, value} | :retry | {:retry, detail}
  """

  @default_deadline_ms 5000
  @default_backoff_ms 10
  @default_max_backoff_ms 200

  import ExUnit.Assertions

  @spec eventually((-> term), keyword) :: term
  def eventually(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    backoff = Keyword.get(opts, :backoff_ms, @default_backoff_ms)
    max_backoff = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    observable = Keyword.get(opts, :observable, "condition")
    retry_on = Keyword.get(opts, :retry_on)

    deadline = System.monotonic_time(:millisecond) + deadline_ms
    loop(fun, deadline_ms, deadline, backoff, max_backoff, observable, retry_on, 0)
  end

  defp loop(fun, deadline_ms, deadline, backoff, max_backoff, observable, retry_on, passes) do
    case attempt(fun, retry_on) do
      {:ok, value} ->
        value

      {:retry, detail} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          flunk(
            "eventually(#{inspect(observable)}): not satisfied within #{deadline_ms}ms " <>
              "(after #{passes + 1} pass(es)) — last value: #{inspect(detail)}"
          )
        end

        Process.sleep(min(backoff, deadline - now))
        loop(fun, deadline_ms, deadline, min(backoff * 2, max_backoff), max_backoff,
             observable, retry_on, passes + 1)
    end
  end

  # One pass. `:retry_on` converts a matching exception into a retry; every
  # other exception reraises with stacktrace.
  defp attempt(fun, nil) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      :retry -> {:retry, :retry}
      {:retry, detail} -> {:retry, detail}

      other ->
        flunk(
          "eventually: fun returned #{inspect(other)} — " <>
            "expected {:ok, value} | :retry | {:retry, detail}"
        )
    end
  end

  defp attempt(fun, {exception_mod, message}) do
    try do
      attempt(fun, nil)
    rescue
      # `rescue e in exception_mod` requires a literal alias; a runtime module
      # value must be matched via __struct__.
      e ->
        if e.__struct__ == exception_mod and Exception.message(e) == message do
          {:retry, Exception.message(e)}
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp attempt(_fun, other_retry_on) do
    raise ArgumentError,
          "eventually: :retry_on must be {ExceptionType, exact_message}, got: #{inspect(other_retry_on)}"
  end
end
```

## Collapse mapping

### 1. i21 `sweep_until_terminal/3` — set-membership poll, driver folded into `fun`

```elixir
eventually(
  fn ->
    {terminal, not_terminal} =
      Enum.split_with(ids, fn id ->
        match?({:ok, %{"status" => "Succeeded", "resourceId" => ^rid}}, Store.get(:smalt_operations, id))
      end)

    missing = Enum.reject(not_terminal, &match?({:ok, _}, Store.get(:smalt_operations, &1)))
    unterminal = not_terminal -- missing

    if missing == [] and unterminal == [] do
      {:ok, :ok}
    else
      :ok = Smalt.ArmGateway.LRO.Sweeper.sweep_now()
      {:retry, %{missing: missing,
                 unterminal: Enum.map(unterminal, &{&1, Store.get(:smalt_operations, &1)})}}
    end
  end,
  observable: "op records reach Succeeded (rid=#{rid})",
  deadline_ms: @sweep_retry_deadline_ms
)
```

The one semantic difference from the original — the `Sweeper.sweep_now()` driver between passes — folds into `fun` before the `{:retry, ...}` return, preserving pass-then-drive ordering with no `on_retry` callback opt. Note the original sleeps 20 ms after sweeping and `eventually`'s own backoff takes over that role.

### 2. i22 `poll_until_succeeded/2` — HTTP poll, immediate-fail arm preserved

```elixir
op =
  eventually(
    fn ->
      conn = conn(:get, path) |> Router.call(@opts)
      parsed = Jason.decode!(conn.resp_body)

      cond do
        parsed["status"] == "Succeeded" ->
          assert conn.status == 200, "expected 200 on terminal poll, got #{conn.status}"
          {:ok, parsed}

        conn.status == 202 ->
          {:retry, "status=#{inspect(parsed["status"])}"}

        true ->
          flunk("unexpected poll status #{conn.status} for #{path}: #{inspect(parsed)}")
      end
    end,
    observable: "LRO reaches Succeeded (path=#{path})",
    deadline_ms: 5000
  )
```

Faithful because `flunk/1` raises `ExUnit.AssertionError`, which is not in `retry_on`, so the "unexpected poll status" arm propagates immediately — identical semantics, zero extra API.

### 3. i22 `resilient_clear` — exception-retry via `retry_on`

```elixir
eventually(
  fn ->
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    {:ok, :cleared}
  end,
  observable: "shared Store clear",
  retry_on: {ArgumentError, "table identifier does not refer to an existing ETS table"}
)
```

Attempt-bound (50 × 10 ms) translates to the 5000 ms default deadline (rationale under Contract). Exact-message matching is preserved verbatim by `attempt/2`; non-matching `ArgumentError`s still reraise.

### 4. Resilient seed pattern — seed inside `fun`

```elixir
eventually(
  fn ->
    ensure_store()
    Store.clear()
    post_seed.()
    {:ok, :seeded}
  end,
  observable: "shared Store clear+seed",
  retry_on: {ArgumentError, "table identifier does not refer to an existing ETS table"}
)
```

`post_seed.()` sits inside `fun`, inside the `retry_on` window — exactly its position inside the c1_arm rescue scope.

## Doc-tests

Two doctests: success return, immediate-fail arm. The deadline-flunk and `retry_on` paths are NOT doctests — their flunk messages carry load-dependent pass counts (measured: the same 20 ms deadline produced a different pass count on the dev machine's smoke run), so they are covered by regular tests asserting on message shape with `Regex.match?` on the "not satisfied within" / "last value:" fragments, and an exact pass-count assertion for the deadline_ms: 0 case.

## Test plan (implementation WO, not this draft)

1. Doctests (2): success return, immediate-fail arm.
2. Deadline flunk message shape: `deadline_ms: 0` → exact message `eventually("never ready"): not satisfied within 0ms (after 1 pass(es)) — last value: :warming` (deterministic: flunk fires on the first retry).
3. `retry_on` match: retries through to success after transient raises (smoke-verified: 2 transient dead-table raises, then success).
4. `retry_on` message mismatch: reraises on pass 1 — assert via a counter in `fun` that exactly one attempt was made (smoke-verified: passes=1, original message preserved).
5. Catch-all arm: `fun` returns `{:error, :x}` → immediate typed failure, zero sleeps (smoke-verified: elapsed=0ms).
6. Backoff cap: `deadline_ms: 60, backoff_ms: 5, max_backoff_ms: 10` → passes bounded by cap, elapsed ~60 ms (smoke-verified: 7 passes, elapsed=61ms, sleep never exceeds remaining deadline).
7. On-exit safety: invoke from an `on_exit` callback — returns normally; no leaked processes.

## Draft-verification receipt (2026-10-18, dev machine, /tmp scratch — frozen tree untouched)

Canonical module compiled clean via `elixirc` (ex_unit from stdlib); functional smoke
of the compiled beam, all real output:

```
case1=:ready                                  # success returns value
case2=eventually("never ready"): not satisfied within 20ms (after 4 pass(es)) — last value: :warming
case3=0                                       # retry_on match: 2 transient dead-table raises, then success
case4=raised passes=1 msg=some other message  # retry_on mismatch reraises immediately
case5=eventually: fun returned {:error, :x} — expected {:ok, value} | :retry | {:retry, detail}  elapsed=0ms
case6=eventually("cap"): not satisfied within 60ms (after 7 pass(es)) — last value: :retry   elapsed=61ms
```

Two compile fixes landed in the draft during this check (found by elixirc, not by eye):
`rescue e in exception_mod` is illegal for a runtime module value (matched via
`e.__struct__` instead), and the module needs `import ExUnit.Assertions` for `flunk/1`.

## Explicitly out of scope

- Call-site migration of the four instances (separate collapse WO).
- `on_retry` driver callback opt (i21 folds faithfully; revisit only if a real call site cannot).
- `max_passes` opt (deadline-bounded is the law).
- Production `lib/` code — `test/support` only.
- Any generated artifact.
