# T29 follow-up (v26.10.20): the RU throttle's 429 previously answered
# `x-ms-retry-after-ms: 1` — a constant 1 ms lets @azure/cosmos burn all 9
# retries inside the same fixed 1 s window (retry-storm class; T29 lane
# witness: 35 rejections with throttle-retry-count 9 in 166 ms). The hint is
# now the remaining-window fraction (remaining_ms ± deterministic key-hash
# jitter, clamped [10, 1000]). Chicago style: real in-process dispatch through
# Smalt.DataPlane.Cosmos.get_doc/4 — real ETS counter, real window state,
# no mocks.
defmodule DataPlane.CosmosRuThrottleRetryAfterTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos

  @limit 3
  @tag :t29_retry_after
  setup do
    # Unique route link per test → own ETS counter cell; no cross-test bleed.
    db = "t29-db-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "t29-coll"
    link = "dbs/#{db}/colls/#{coll}"
    headers = %{}

    prev = System.get_env("SMALT_COSMOS_RU_LIMIT")
    System.put_env("SMALT_COSMOS_RU_LIMIT", Integer.to_string(@limit))

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("SMALT_COSMOS_RU_LIMIT")
        v -> System.put_env("SMALT_COSMOS_RU_LIMIT", v)
      end
    end)

    %{link: link, headers: headers}
  end

  test "429 retry-after is the remaining-window fraction, clamped [10, 1000] ms", %{
    link: link,
    headers: headers
  } do
    {statuses, hints} = burst(link, headers, 15)

    # Throttle really fires on the real counter (retry-storm regression guard).
    assert Enum.count(statuses, &(&1 == 429)) >= @limit

    for v <- hints do
      assert v >= 10 and v <= 1000, "retry-after #{v} outside [10, 1000]"
    end

    # The hint must be consistent with the window state observed at request
    # time: at most remaining_ms + 5 (deterministic jitter), floored at 10.
    now_ms = System.system_time(:millisecond)
    remaining_ms = 1000 - rem(now_ms, 1000)
    assert hd(hints) <= max(10, remaining_ms + 5)
  end

  test "hint tracks the draining window (changes across window boundaries)", %{
    link: link,
    headers: headers
  } do
    {_, hints1} = burst(link, headers, 15)
    assert hints1 != []
    now1_ms = System.system_time(:millisecond)

    # Poll the real observable (epoch-second window flip) — a bounded spin on
    # the wall clock, never a fixed sleep.
    wait_window_flip()

    # Fresh window: the counter cell ({link, new_epoch}) starts empty, so the
    # first requests pass and only the over-limit tail is throttled again.
    hints2 = burst(link, headers, 15) |> elem(1)
    assert hints2 != [], "expected throttled responses in window 2"

    now2_ms = System.system_time(:millisecond)
    hint2 = hd(hints2)
    assert hint2 >= 10 and hint2 <= 1000

    remaining1 = 1000 - rem(now1_ms, 1000)
    remaining2 = 1000 - rem(now2_ms, 1000)

    # When the two windows were observed far enough apart in their drain
    # phase, the hint MUST differ — the old constant "1" could never satisfy
    # this; the remaining-fraction does. (Jitter is ±5, hence the 10 ms
    # separation guard.)
    if abs(remaining1 - remaining2) > 10 do
      assert hint2 != hd(hints1), "hint did not track the draining window"
    end
  end

  # Burst get_doc reads against the real gate: statuses + the 429
  # x-ms-retry-after-ms hints in arrival order.
  defp burst(link, headers, n) do
    "dbs/" <> rest = link
    [db, "colls", coll] = String.split(rest, "/")

    results =
      for _ <- 1..n do
        {:ok, status, resp_headers, _body} = Cosmos.get_doc(db, coll, "no-such-doc", headers)
        hint = if status == 429, do: retry_after(resp_headers), else: nil
        {status, hint}
      end

    statuses = Enum.map(results, &elem(&1, 0))
    hints = results |> Enum.filter(&(elem(&1, 0) == 429)) |> Enum.map(&elem(&1, 1))
    {statuses, hints}
  end

  defp retry_after(headers) do
    String.to_integer(Map.fetch!(headers, "x-ms-retry-after-ms"))
  end

  # Bounded spin until the epoch-second window flips (observable poll).
  defp wait_window_flip do
    start = div(System.system_time(:millisecond), 1000)
    deadline = System.system_time(:millisecond) + 2500
    spin(start, deadline)
  end

  defp spin(start, deadline) do
    cond do
      div(System.system_time(:millisecond), 1000) != start -> :ok
      System.system_time(:millisecond) > deadline -> flunk("window did not flip within budget")
      true -> spin(start, deadline)
    end
  end
end
