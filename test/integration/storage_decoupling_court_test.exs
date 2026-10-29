defmodule Smalt.Integration.StorageDecouplingCourt do
  # SJ-3 — end-to-end storage-decoupling court (operator reference:
  # court_storage_decoupling). Proves the emit path is decoupled from the
  # storage path with real artifacts, not mocks: a real file, real CRC32
  # frames, a real independent reader task, and a real 1-bit tamper.
  #
  # Gates:
  #   1. sink boot (real GenServer, real fd on a tmp file)
  #   2. 50k-event concurrent emit (32 tasks), mean ns/op MEASURED and
  #      fenced <= 2000 ns/op (2 us) — the failure message carries the
  #      measured number, the fence is typed against it, never invented
  #   3. drain (bounded poll), seal, sentinel discovery by an INDEPENDENT
  #      reader task (file-only, zero server contact)
  #   4. 50k-frame clean parse, 100% CRC32 validity
  #   5. non-vacuity tamper: 1-bit flip in the first and in a middle byte
  #      -> typed {:crc_mismatch, offset}, never a silent pass
  #
  # Chicago discipline: real collaborators only (GenServer, file, tasks);
  # assertions on final state (file bytes, reader verdict), never call counts.

  # single audited poll implementation (no-sleep doctrine) — drained via
  # SmaltTest.Internal.Poll.eventually/2 (test/internal/poll_helper.exs)
  Code.require_file(Path.join("internal", "poll_helper.exs"), Path.expand("test", File.cwd!()))

  use ExUnit.Case, async: false

  @event_count 50_000
  @concurrency 32
  @fence_ns 2_000
  @sink_tmp Path.expand("tmp/sj3-courts")

  defp unique_path(tag),
    do: Path.join(@sink_tmp, "sealed-#{tag}-#{System.unique_integer([:positive])}.bin")

  test "gates 1-5: sink boot, 50k decoupled emit, seal+sentinel, clean parse, 1-bit tamper" do
    path = unique_path("main")

    # ---- Gate 1: sink boot -------------------------------------------------
    pid = start_supervised!({Smalt.Telemetry.SealedLog, path: path})
    assert Process.alive?(pid), "gate 1 REFUSED: sink process not alive after boot"

    # ---- Gate 2: 50k concurrent emit, measured mean ns/op, <= 2us fence ----
    events =
      for i <- 1..@event_count do
        %{
          "id" => "e#{i}",
          "type" => "sj3.court.event",
          "time" => "2026-10-21T00:00:00Z",
          "attributes" => %{"seq" => i, "lane" => "SJ-3"}
        }
      end

    # persistent tasks, tight cast loops: measures the emit path itself
    # (GenServer.cast), not per-event task-spawn overhead.
    t0 = System.monotonic_time(:nanosecond)

    tasks =
      for chunk <- Enum.chunk_every(events, div(@event_count, @concurrency)) do
        Task.async(fn ->
          Enum.each(chunk, &Smalt.Telemetry.SealedLog.emit/1)
        end)
      end

    Task.await_many(tasks, 120_000)

    t1 = System.monotonic_time(:nanosecond)
    elapsed_ns = t1 - t0
    mean_ns = div(elapsed_ns, @event_count)
    IO.puts(
      "[SJ-3] gate 2 measured emit mean: #{mean_ns} ns/op " <>
        "(#{@event_count} events, #{div(elapsed_ns, 1_000_000)} ms wall, #{@concurrency} tasks)"
    )

    assert mean_ns <= @fence_ns,
           "gate 2 REFUSED: measured emit mean #{mean_ns} ns/op exceeds the #{@fence_ns} ns/op fence"

    # ---- Gate 3: drain (bounded poll), seal, independent reader -----------
    {:ok, count} =
      SmaltTest.Internal.Poll.eventually(
        fn ->
          # patient call: the sink legitimately has a 50k-deep cast backlog
          # to write through — the probe must not timeout ahead of the drain
          if GenServer.call(pid, :persisted, 60_000) == @event_count,
            do: {:ok, @event_count},
            else: {:error, :draining}
        end,
        timeout_ms: 300_000
      )

    assert count == @event_count

    {:ok, sealed_count} = Smalt.Telemetry.SealedLog.seal(pid)
    assert sealed_count == @event_count

    # post-seal immutability: a late cast must not append
    :ok =
      Smalt.Telemetry.SealedLog.emit(pid, %{
        "id" => "late",
        "type" => "sj3.court.event",
        "time" => "2026-10-21T00:00:00Z",
        "attributes" => %{}
      })

    {:ok, sealed_again} = Smalt.Telemetry.SealedLog.seal(pid)
    assert sealed_again == @event_count
    IO.puts("[SJ-3] gate 3 PASS: drained 50000, seal sentinel written, post-seal emit ignored (seal count still 50000)")

    # INDEPENDENT reader: a fresh task whose only input is the file —
    # `read_frames/1` is pure and never contacts the sink process.
    reader_result =
      Task.async(fn -> Smalt.Telemetry.SealedLog.read_frames(path) end)
      |> Task.await(120_000)

    assert {:ok, %{frames: frames, sentinel: sentinel}} = reader_result
    assert length(frames) == @event_count
    assert is_map(sentinel) and is_integer(sentinel.offset)
    assert to_string(sentinel.payload) |> String.starts_with?(Smalt.Telemetry.SealedLog.seal_magic())

    # ---- Gate 4: clean parse = every frame CRC-valid, well-formed payloads -
    assert Enum.all?(frames, fn %{payload: p} -> is_binary(p) and p != "" end)
    decoded = Enum.map(frames, &Jason.decode!(Map.fetch!(&1, :payload)))
    assert MapSet.size(MapSet.new(decoded, & &1["id"])) == @event_count
    IO.puts("[SJ-3] gate 4 PASS: 50000-frame clean parse, 100% CRC32 validity, 50000 unique event ids")

    # ---- Gate 5: non-vacuity 1-bit tamper -> typed CRC rejection ----------
    tampered = unique_path("tampered")
    File.cp!(path, tampered)
    bin = File.read!(tampered)
    assert byte_size(bin) > Smalt.Telemetry.SealedLog.header_bytes() + 16

    # leg A: flip 1 bit in the FIRST payload byte of frame 0
    <<head::binary-size(8), rest::binary>> = bin
    <<first::integer-size(8), tail::binary>> = rest
    flipped = :erlang.bxor(first, 1)
    File.write!(tampered, <<head::binary, flipped::size(8), tail::binary>>)

    assert {:error, {:crc_mismatch, 0}} = Smalt.Telemetry.SealedLog.read_frames(tampered)

    # leg B: flip 1 bit at the middle of the file (inside some later frame)
    mid = div(byte_size(bin), 2)
    <<h2::binary-size(mid), bit::integer-size(8), t2::binary>> = bin
    flipped2 = :erlang.bxor(bit, 0x80)
    File.write!(tampered, <<h2::binary, flipped2::size(8), t2::binary>>)

    assert {:error, {:crc_mismatch, _}} = Smalt.Telemetry.SealedLog.read_frames(tampered)
    IO.puts("[SJ-3] gate 5 PASS: 1-bit flips (frame-0 byte 0; file midpoint) -> typed {:crc_mismatch, offset}")
  end
end
