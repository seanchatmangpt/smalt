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
          observable, retry_on, passes + 1
        )
    end
  end

  @doc """
  `eventually_stays/2` polls `fun/0` until it has held truthy CONTINUOUSLY for
  `:stability_ms` (default 50) within `:within_ms` (default 5000) — the honest
  form of assert-absence: absence cannot be proven by a first-poll-true, only
  by a stability window.

  Truthy semantics: `nil`/`false` keep polling; anything else counts. An
  exception inside `fun/0` is captured as a false observation (it rides the
  typed flunk on timeout) — the commonest poll body is an ETS/`Store.get`
  match that raises while state is still settling. Any observation flip
  false→true resets the stability clock.

  On timeout the flunk is typed: names `desc`, `:stability_ms`, and the LAST
  observation, never a bare timeout.

  ## Examples

      iex> SmaltTest.AssertEventually.eventually_stays(fn -> true end,
      ...>   stability_ms: 1, interval_ms: 1, desc: "always true")
      :ok

      iex> SmaltTest.AssertEventually.eventually_stays(fn -> false end,
      ...>   within_ms: 20, stability_ms: 5, desc: "never true")
      ** (ExUnit.AssertionError) eventually_stays(never true) never held stable for 5ms within 20ms; last observation: false
  """

  @spec eventually_stays((-> term), keyword) :: :ok | no_return
  def eventually_stays(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    within_ms = Keyword.get(opts, :within_ms, @default_deadline_ms)
    stability_ms = Keyword.get(opts, :stability_ms, 50)
    interval = Keyword.get(opts, :interval_ms, @default_backoff_ms)
    desc = Keyword.get(opts, :desc, "condition")

    deadline = System.monotonic_time(:millisecond) + within_ms
    stable(fun, deadline, within_ms, stability_ms, interval, desc, nil, nil)
  end

  # condition must hold truthy continuously for stability_ms
  defp stable(fun, deadline, within_ms, stability_ms, interval, desc, stable_since, last) do
    now = System.monotonic_time(:millisecond)

    cond do
      stable_since != nil and now - stable_since >= stability_ms ->
        :ok

      now >= deadline ->
        flunk(
          "eventually_stays(#{desc}) never held stable for #{stability_ms}ms " <>
            "within #{within_ms}ms; last observation: #{inspect(last)}"
        )

      true ->
        case safe(fun) do
          {true, value} ->
            since = stable_since || now
            Process.sleep(min(interval, deadline - now))
            stable(fun, deadline, within_ms, stability_ms, interval, desc, since, value)

          {false, value} ->
            Process.sleep(min(interval, max(deadline - now, 0)))
            stable(fun, deadline, within_ms, stability_ms, interval, desc, nil, value)
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
