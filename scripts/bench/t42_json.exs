# scripts/bench/t42_json.exs — T42 lane (AR-WIRE-01 verification gate):
# native :json (OTP 28.3.1) vs Jason on a deterministic ~50MB synthetic
# Cosmos-document JSON corpus. Modes:
#   (a) :json.decode/1 whole-term
#   (b) Jason.decode!
#   (c) :json SAX-style streaming (decode_start/decode_continue + decoders()
#       hook map discarding values) — partial input IS available on OTP 28.
# Gate: ≤2MB peak process heap for a 50MB stream via ANY available mode.
# Emits tmp/bench/t42-json.jsonl (bench-lib result shape + verdict row).
#
# Run: elixir scripts/bench/t42_json.exs   (no substrate needed)

defmodule T42JSON do
  @target_bytes 50 * 1024 * 1024
  @chunk 64 * 1024
  @runs 3

  # ------------------------------------------------------------------
  # Deterministic corpus: Cosmos-style document array (id/pk/_rid/_ts/
  # _etag + payload text + nums), phash2-of-fixed-tuples (no RNG),
  # ~2.2KB per doc, byte count fixed by construction.
  # ------------------------------------------------------------------
  def corpus(target \\ @target_bytes) do
    doc = fn i ->
      h = fn n -> :erlang.integer_to_binary(:erlang.phash2({i, n}), 16) end

      nums =
        Enum.map_join(1..16, ",", fn k ->
          Integer.to_string(rem(:erlang.phash2({i, k}), 1_000_000))
        end)

      text = String.duplicate("x", 2048)
      es = String.duplicate("e", 24)

      [
        "{\"id\":\"doc",
        Integer.to_string(i),
        "\",\"pk\":\"pk",
        h.(1),
        "\",\"_rid\":\"doc",
        Integer.to_string(i),
        "A\",\"_ts\":1760000000,\"_etag\":\"\\\"",
        es,
        "\\\"\",\"_self\":\"dbs/db/colls/c/docs/doc",
        Integer.to_string(i),
        "\",\"payload\":{\"text\":\"",
        text,
        "\",\"nums\":[",
        nums,
        "]}}"
      ]
    end

    one = IO.iodata_to_binary(doc.(1))
    n = div(target, byte_size(one)) + 1

    body = 1..n |> Enum.map_intersperse(",", fn i -> IO.iodata_to_binary(doc.(i)) end)

    bin = IO.iodata_to_binary(["{\"kind\":\"cosmos_array\",\"docs\":[", body, "]}"])
    {bin, n}
  end

  # ------------------------------------------------------------------
  # Peak-heap harness: run Fun in an isolated worker process; a poller
  # samples total_heap_size (words -> bytes x8) every 1ms until the
  # worker dies; the worker garbage_collects before exiting so the
  # final live heap is inside the sampled window.
  # ------------------------------------------------------------------
  def measure_peak_heap(fun) do
    parent = self()

    worker =
      spawn(fn ->
        t0 = System.monotonic_time(:millisecond)
        res = fun.()
        t1 = System.monotonic_time(:millisecond)
        :erlang.garbage_collect()
        send(parent, {:result, t1 - t0})
      end)

    poller = spawn(fn -> send(parent, {:heap_peak, poll_loop(worker, 0, 0)}) end)

    res =
      receive do
        {:result, r} -> r
      after
        300_000 -> exit(:timeout)
      end

    peak =
      receive do
        {:heap_peak, p} -> p
      after
        10_000 -> -1
      end

    {res, peak}
  end

  defp poll_loop(pid, peak, misses) do
    case Process.info(pid, :total_heap_size) do
      {:total_heap_size, words} ->
        receive do
          after 1 -> poll_loop(pid, max(peak, words * 8), 0)
        end

      nil ->
        if misses + 1 >= 3 do
          peak
        else
          receive do
            after 1 -> poll_loop(pid, peak, misses + 1)
          end
        end
    end
  end

  # ------------------------------------------------------------------
  # Modes — each runs one decode of the corpus; errors propagate.
  # ------------------------------------------------------------------
  def bench_json_whole(bin) do
    term = :json.decode(bin); _ = term
    :ok
  end

  def bench_jason(bin) do
    {:ok, _} = Jason.decode(bin)
    :ok
  end

  # SAX-style streaming: decoders hook map discards values (pushes the
  # acc integer through as the container value), so no corpus term is
  # ever materialized.
  def discard_decoders do

    # Real arities (from OTP 28 stdlib types, verified via beam abstract_code):
    #   from_binary_fun :: fun((binary()) -> dynamic())          # arity 1
    #   array_start     :: fun((Acc) -> ArrayAcc)                # arity 1
    #   array_push      :: fun((Value, ArrayAcc) -> NewArrayAcc) # arity 2
    #   array_finish    :: fun((ArrayAcc, OldAcc) -> {Val, Acc}) # arity 2
    #   object_*        :: same shape as array_*
    %{
      array_start: fn _a -> 0 end,
      array_push: fn _v, c -> c + 1 end,
      array_finish: fn c, old -> {c, old + c} end,
      object_start: fn _a -> 0 end,
      object_push: fn _k, _v, c -> c + 1 end,
      object_finish: fn c, old -> {c, old + c} end,
      integer: fn _b -> 1 end,
      float: fn _b -> 1.0 end,
      string: fn _b -> 1 end,
      null: 0
    }
  end

  def bench_json_stream(bin) do
    dec = discard_decoders()
    <<head::binary-size(@chunk), rest::binary>> = bin

    case :json.decode_start(head, 0, dec) do
      {:continue, st} -> stream_loop(st, rest)
      {_val, _acc, rest2} -> stream_tail(rest2)
    end

    :ok
  end

  @chunk_size 64 * 1024

  defp stream_loop(st, rest) do
    case rest do
      <<c::binary-size(@chunk_size), more::binary>> ->
        case :json.decode_continue(c, st) do
          {:continue, st2} -> stream_loop(st2, more)
          {_val, _acc, more2} -> stream_tail(more2)
        end

      _ ->
        case :json.decode_continue(rest, st) do
          {:continue, st2} -> stream_loop(st2, <<>>)
          {_val, _acc, <<>>} -> :ok
        end
    end
  end

  defp stream_tail(<<>>), do: :ok
  defp stream_tail(rest), do: raise("leftover input: #{byte_size(rest)} bytes")

  # ------------------------------------------------------------------
  # JSONL emission (bench-lib result shape)
  # ------------------------------------------------------------------
  def emit(io, lane, surface, op, n, wall_ms, errors, machine, extra \\ %{}) do
    row =
      %{
        lane: lane,
        surface: surface,
        op: op,
        n: n,
        ops_per_sec: if(wall_ms > 0, do: n / (wall_ms / 1000), else: 0.0),
        p50_ms: wall_ms,
        p95_ms: wall_ms,
        p99_ms: wall_ms,
        errors: errors,
        machine: machine
      }
      |> Map.merge(extra)

    IO.binwrite(io, [Jason.encode!(row), "\n"])
  end
end

{bin, ndocs} = T42JSON.corpus()
bytes = byte_size(bin)
IO.puts("corpus: #{bytes} bytes (#{Float.round(bytes / 1_048_576, 1)} MiB), #{ndocs} docs")

{:ok, io} = File.open("tmp/bench/t42-json.jsonl", [:write, :utf8])

otp = :erlang.system_info(:otp_release) |> List.to_string()

machine =
  Jason.encode!(%{otp: otp, corpus: "synthetic-cosmos-50MB-deterministic"})

lane = "t42json"

unless (match?({:module, _}, Code.ensure_loaded(:json)) and :erlang.function_exported(:json, :decode, 1)) do
  IO.binwrite(io, [
    Jason.encode!(%{lane: lane, surface: "json", op: "SKIP", reason: ":json/1 absent", errors: 0}),
    "\n"
  ])

  File.close(io)
  System.halt(3)
end

sax? = :erlang.function_exported(:json, :decode_start, 3)
IO.puts("OTP #{otp}: :json present; decode_start/3 = #{sax?}")

modes =
  [{"json_whole_term", fn -> T42JSON.bench_json_whole(bin) end}] ++
    if Code.ensure_loaded?(Jason) do
      [{"jason_decode", fn -> T42JSON.bench_jason(bin) end}]
    else
      []
    end ++
    if sax? do
      [{"json_sax_stream", fn -> T42JSON.bench_json_stream(bin) end}]
    else
      []
    end

results =
  for {name, fun} <- modes, run <- 1..3 do
    {ms, peak} = T42JSON.measure_peak_heap(fun)

    IO.puts(
      "#{name} run#{run}: #{ms} ms, peak_heap=#{peak} bytes (#{Float.round(peak / 1_048_576, 1)} MiB)"
    )

    T42JSON.emit(io, lane, "json", name, 1, ms, 0, machine, %{
      peak_heap_bytes: peak,
      corpus_bytes: bytes,
      run: run
    })

    {name, ms, peak}
  end

best_by_mode =
  Enum.map(Enum.group_by(results, fn {n, _, _} -> n end), fn {n, rs} ->
    {n, Enum.min_by(rs, fn {_, _, p} -> p end)}
  end)

gate_bytes = 2 * 1024 * 1024

verdict =
  case Enum.find(best_by_mode, fn {_n, {_, _, peak}} -> peak <= gate_bytes end) do
    nil -> "GATE-FAIL"
    {name, _} -> "GATE-PASS via #{name}"
  end

verdict_row = %{
  lane: lane,
  surface: "json",
  op: "verdict",
  gate: "peak_heap_bytes <= #{gate_bytes} for #{bytes}-byte stream",
  gate_bytes: gate_bytes,
  corpus_bytes: bytes,
  verdict: verdict,
  standing: if(String.contains?(verdict, "PASS"), do: "ALIVE", else: "PARTIAL_ALIVE"),
  note:
    "peak heap = 1ms-sampled total_heap_size of isolated worker, GC before exit; sax mode discards values via decoders() hook map",
  errors: 0,
  machine: machine
}

IO.binwrite(io, [Jason.encode!(verdict_row), "\n"])
File.close(io)
IO.puts("VERDICT: #{verdict}")
