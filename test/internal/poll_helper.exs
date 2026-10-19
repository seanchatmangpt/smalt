# Residual internal tier — bounded-poll helper (clean-room re-derivation,
# WO-10). Required by each test file via:
#
#     Code.require_file("poll_helper.exs", __DIR__)
#
# This is the ONLY file in test/internal permitted to pace on time: the
# single audited poll implementation lives here (no-sleep doctrine,
# docs/NO_SLEEP_DOCTRINE.md). Every consumer pollObservably.

defmodule SmaltTest.Internal.Poll do
  @moduledoc """
  Bounded observable poll. `eventually/2` runs `fun` until it returns
  `{:ok, value}` or the deadline passes.

  Fail-closed contract: ANY other return shape (`:ok`, plain values,
  `{:error, _}`, raises) is treated as not-yet-converged — a fun that
  never returns `{:ok, _}` can only ever end in the typed timeout, never
  in a faked pass.

  Returns:

    * `{:ok, value}` — fun converged;
    * `{:timeout, last}` — deadline passed; `last` is the most recent
      non-{:ok, _} result (or the last raised reason).
  """

  @default_timeout_ms 5_000
  @default_poll_ms 50

  @spec eventually((-> term()), keyword()) :: {:ok, term()} | {:timeout, term()}
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline, poll_ms, nil)
  end

  defp poll(fun, deadline, poll_ms, _last) do
    result =
      try do
        {:res, fun.()}
      rescue
        e -> {:raise, e}
      end

    case result do
      {:res, {:ok, value}} ->
        {:ok, value}

      {:res, other} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, other}
        else
          pace(fun, deadline, poll_ms, other)
        end

      # An unexpected shape is retried, never swallowed: the raise is
      # preserved as `last` so the typed timeout carries the real reason.
      {:raise, e} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, Exception.message(e)}
        else
          pace(fun, deadline, poll_ms, {:raise, e})
        end
    end
  end

  # SLEEP-CLASS: POLL-STEP — the one audited poll implementation in the
  # residual internal tier; paces the observable retry loop only.
  defp pace(fun, deadline, poll_ms, last) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      Process.sleep(min(poll_ms, remaining))
      poll(fun, deadline, poll_ms, last)
    else
      {:timeout, last}
    end
  end
end
