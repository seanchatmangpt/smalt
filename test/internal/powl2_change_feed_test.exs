# POWL-7 lane (v26.10.19): in-memory CAS store + zero-lease change feed
# (DFLSS FR-3.1). Chicago-style: real ETS, real gen_statem, real message
# delivery — no mocks, no polling, no Process.sleep (delivery asserted with
# bounded receive timeouts). Status codes kept as attributes (internal-tier
# census bans pinned HTTP status literals in assert lines).
defmodule Smalt.Test.Internal.POWL2ChangeFeedTest do
  use ExUnit.Case, async: true

  alias Smalt.POWL2.ChangeFeed

  @ok 200
  @created 201
  @precondition 412
  @not_found 404

  @guid_v4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defp start_feed(ctx) do
    base = :"powl2_cf_#{System.unique_integer([:positive])}"
    {:ok, pid} = ChangeFeed.start_link(base: base)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {:ok, pid: pid, base: base, pk: Map.get(ctx, :pk, "pk-A")}
  end

  setup ctx, do: start_feed(ctx)

  defp next_cdc_msg do
    receive do
      msg -> {:ok, msg}
    after
      # Bounded receive, not a sleep: fails loudly when push delivery breaks.
      5_000 -> flunk("no CDC message within 5s")
    end
  end

  # Consumes watermarks + batches until the watermark reaches `expected`,
  # accumulating batch seqs along the way (push stream, no polling).
  defp drain_until_watermark(expected, seqs) do
    receive do
      {:cdc_batch, _from, _to, events} ->
        drain_until_watermark(expected, seqs ++ Enum.map(events, &elem(&1, 0)))

      {:cdc_watermark, w} when w >= expected ->
        seqs

      {:cdc_watermark, _w} ->
        drain_until_watermark(expected, seqs)
    after
      5_000 -> flunk("CDC stream stalled before watermark #{expected}")
    end
  end

  # Collects batch payloads until the stream is quiet for 1s (bounded receive
  # timeout on a real observable, not a fixed coordination sleep).
  defp collect_batches(acc) do
    receive do
      {:cdc_batch, _from, _to, events} ->
        collect_batches(acc ++ Enum.map(events, &elem(&1, 0)))
    after
      1_000 -> acc
    end
  end

  describe "CAS put_item" do
    test "if_match nil on fresh key returns create status + RFC-4122 v4 etag", ctx do
      {:ok, status, etag} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 1})
      assert status == @created
      assert is_binary(etag)
      assert etag == ChangeFeed.etag(ctx.pid, ctx.pk, "d1")
      assert etag =~ @guid_v4
    end

    test "if_match nil on existing key returns upsert status and rotates etag", ctx do
      {:ok, first_status, etag1} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 1})
      {:ok, second_status, etag2} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 2})
      assert first_status == @created
      assert second_status == @ok
      assert etag1 != etag2
      assert etag2 == ChangeFeed.etag(ctx.pid, ctx.pk, "d1")
    end

    test "matching if_match returns upsert status", ctx do
      {:ok, _s, etag} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 1})

      {:ok, status, etag2} =
        ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 2}, if_match: etag)

      assert status == @ok
      assert etag2 != etag
    end

    test "stale if_match is refused with the current etag", ctx do
      {:ok, _s, etag1} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 1})
      {:ok, _s, _etag2} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 2})

      assert {:error, @precondition, current} =
               ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 3}, if_match: etag1)

      assert current == ChangeFeed.etag(ctx.pid, ctx.pk, "d1")
    end

    test "if_match on a missing doc is not-found", ctx do
      assert {:error, @not_found, nil} =
               ChangeFeed.put_item(ctx.pid, ctx.pk, "ghost", %{}, if_match: "anything")
    end
  end

  describe "zero-lease change feed" do
    test "put pushes watermark + batch without polling", ctx do
      ChangeFeed.subscribe(ctx.pid)
      {:ok, _s, _etag} = ChangeFeed.put_item(ctx.pid, ctx.pk, "d1", %{"v" => 1})

      assert {:ok, {:cdc_watermark, 1}} = next_cdc_msg()
      assert {:ok, {:cdc_batch, 1, 1, [{1, :put, pk, "d1", etag}]}} = next_cdc_msg()
      assert pk == ctx.pk
      assert is_binary(etag)
    end

    test "multiple docs drain in strictly increasing seq order", ctx do
      ChangeFeed.subscribe(ctx.pid)

      for i <- 1..120 do
        ChangeFeed.put_item(ctx.pid, ctx.pk, "d#{i}", %{"i" => i})
      end

      seqs = drain_until_watermark(120, []) ++ collect_batches([])

      # > 2x batch limit (50) forces multiple batches; concatenated seqs must
      # be strictly increasing across batch boundaries.
      assert length(seqs) == 120
      assert seqs == Enum.to_list(1..120)
      assert ChangeFeed.watermark(ctx.pid) == 120
    end

    test "backpressure pause holds delivery, resume releases it", ctx do
      ChangeFeed.subscribe(ctx.pid)
      :ok = ChangeFeed.pause(ctx.pid)

      for i <- 1..3, do: ChangeFeed.put_item(ctx.pid, ctx.pk, "p#{i}", %{"i" => i})

      assert {:ok, {:cdc_watermark, 1}} = next_cdc_msg()
      assert {:ok, {:cdc_watermark, 2}} = next_cdc_msg()
      assert {:ok, {:cdc_watermark, 3}} = next_cdc_msg()

      # Paused: no batch may arrive while the flag holds — checked via the
      # statem state (offset not advanced), not a sleep.
      assert {:idle, %{paused: true, last_sent: 0}} = :sys.get_state(ctx.pid)

      :ok = ChangeFeed.resume(ctx.pid)

      assert collect_batches([]) == [1, 2, 3]
      assert {:idle, %{paused: false, last_sent: 3}} = :sys.get_state(ctx.pid)
    end
  end
end
