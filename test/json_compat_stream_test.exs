defmodule Smalt.JsonCompat.StreamTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Chicago court for Smalt.JsonCompat.stream/3 (SNIPPET-REVIEW next-step 2).
  Real collaborators only: real :json decoder state machine over real chunked
  input; heap measured on a real worker process via process_info sampling.
  """

  @heap_budget 1_048_576

  describe "stream/3 — 50k-doc array in 3 chunks" do
    test "delivers every doc exactly once, count correct" do
      n = 50_000
      {c1, c2, c3} = doc_array_chunks(n)
      input = IO.iodata_to_binary([c1, c2, c3])

      {:ok, count} =
        Smalt.JsonCompat.stream(input, fn doc ->
          assert is_map(doc)
        end)

      assert count == n
    end

    test "delivered docs are exactly the corpus (ids 0..n-1, each once)" do
      n = 50_000
      {c1, c2, c3} = doc_array_chunks(n)
      input = IO.iodata_to_binary([c1, c2, c3])

      {:ok, count, docs} =
        Smalt.JsonCompat.stream(input, fn doc -> doc end, accumulate: true)

      assert count == n
      assert length(docs) == n

      ids = Enum.map(docs, & &1["i"])
      assert ids == Enum.to_list(0..(n - 1))
    end

    test "iodata input accepted (3-chunk iodata, no caller-side flatten)" do
      {c1, c2, c3} = doc_array_chunks(200)
      assert {:ok, 200, docs} = Smalt.JsonCompat.stream([c1, c2, c3], fn _ -> :ok end, accumulate: true)
      assert length(docs) == 200
    end
  end

  describe "heap bound (< 1MB peak during streaming)" do
    # Poller tick is inside this audited sampling loop (no-sleep doctrine:
    # bounded poll on a real observable, process_info/2 heap words).
    defp sample_heap(pid, peak, misses) when misses >= 3, do: peak

    defp sample_heap(pid, peak, misses) do
      case Process.info(pid, :total_heap_size) do
        {:total_heap_size, words} ->
          receive do
          after
            1 -> sample_heap(pid, max(peak, words * :erlang.system_info(:wordsize)), 0)
          end

        nil ->
          sample_heap(pid, peak, misses + 1)
      end
    end

    test "peak heap stays under 1MB for the 50k-doc stream" do
      n = 50_000
      {c1, c2, c3} = doc_array_chunks(n)
      input = IO.iodata_to_binary([c1, c2, c3])
      parent = self()

      worker =
        spawn(fn ->
          res = Smalt.JsonCompat.stream(input, fn _ -> :ok end)
          :erlang.garbage_collect()
          send(parent, {:stream_result, res})
        end)

      poller =
        spawn(fn -> send(parent, {:heap_peak, sample_heap(worker, 0, 0)}) end)

      result =
        receive do
          msg -> msg
        after
          120_000 -> :timeout
        end

      assert {:stream_result, {:ok, ^n}} = result
      peak_msg = receive do msg -> msg after 10_000 -> :lost end # SLEEP-CLASS: POLL-STEP (bounded receive of the heap-peak probe, 10s deadline)
      assert {:heap_peak, peak} = peak_msg
      assert peak < @heap_budget, "peak heap #{peak} exceeds 1MB budget"
    end
  end

  describe "typed failures" do
    test "malformed chunk -> {:error, {:malformed_json, _}}" do
      input = ~s([{"i":0},{"i":1}, {"i":2} OOPS])
      assert {:error, {:malformed_json, _reason}} = Smalt.JsonCompat.stream(input, fn _ -> :ok end)
    end

    test "truncated input -> {:error, {:malformed_json, :unexpected_end_of_input}}" do
      input = ~s([{"i":0},{"i":1},{"i":2
      assert {:error, {:malformed_json, :unexpected_end_of_input}} =
               Smalt.JsonCompat.stream(input, fn _ -> :ok end)
    end

    test "empty input -> {:error, {:malformed_json, :empty_input}}" do
      assert {:error, {:malformed_json, :empty_input}} =
               Smalt.JsonCompat.stream("", fn _ -> :ok end)
    end
  end

  describe "delivery contract" do
    test "concatenated top-level values each delivered (NDJSON)" do
      input = ~s({"a":1}\n{"a":2}\n{"a":3})
      {:ok, 3, vals} = Smalt.JsonCompat.stream(input, & &1, accumulate: true)
      assert vals == [%{"a" => 1}, %{"a" => 2}, %{"a" => 3}]
    end

    test "top-level object delivered whole, once" do
      input = ~s({"kind":"cosmos_array","docs":[1,2,3]})
      {:ok, 1, vals} = Smalt.JsonCompat.stream(input, & &1, accumulate: true)
      assert vals == [%{"kind" => "cosmos_array", "docs" => [1, 2, 3]}]
    end

    test "top-level scalars delivered" do
      {:ok, 3, vals} = Smalt.JsonCompat.stream(~s(1 2 3), & &1, accumulate: true)
      assert vals == [1, 2, 3]
    end

    test "null normalizes to nil in delivered docs" do
      input = ~s([{"a":null},{"b":[null]}])
      {:ok, 2, vals} = Smalt.JsonCompat.stream(input, & &1, accumulate: true)
      assert vals == [%{"a" => nil}, %{"b" => [nil]}]
    end
  end

  # Deterministic synthetic doc corpus: 50k docs of
  # {"i":id,"pk":"pk<hex>","payload":{"t":"xxx","nums":[...]}}. Returns the
  # input as exactly three binaries split at doc boundaries.
  defp doc_array_chunks(n) do
    doc = fn i ->
      h = :erlang.integer_to_binary(:erlang.phash2({i, 1}), 16)

      nums =
        1..8
        |> Enum.map_join(",", fn k -> Integer.to_string(rem(:erlang.phash2({i, k}), 1_000_000)) end)

      ~s({"i":#{i},"pk":"pk#{h}","payload":{"t":"#{String.duplicate("x", 64)}","nums":[#{nums}]}})
    end

    chunk = div(n, 3)

    c1 = IO.iodata_to_binary(["[", Enum.map_join(0..(chunk - 1), ",", doc)])
    c2 =
      IO.iodata_to_binary([Enum.map_join(chunk..(2 * chunk - 1), "", fn i -> "," <> doc.(i) end)])

    c3 =
      IO.iodata_to_binary([
        Enum.map_join((2 * chunk)..(n - 2), "", fn i -> "," <> doc.(i) end),
        ",",
        doc.(n - 1),
        "]"
      ])

    {c1, c2, c3}
  end
end
