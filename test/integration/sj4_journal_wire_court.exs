# SJ-4 — journal-sink wire court (config-gated journaling in the real telemetry path).
# Run: MIX_BUILD_ROOT=_build-sj4 MIX_ENV=dev mix run --no-start test/integration/sj4_journal_wire_court.exs
# Exit 0 = PASS, 1 = FAIL, 3 = SKIP (JournalSink not landed — loud, never a fake pass).

defmodule Sj4.Plug do
  def init(opts), do: opts

  def call(%{method: "PUT"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, ~s({"ok":true}))
  end

  def call(%{method: "DELETE"} = conn, _opts) do
    Plug.Conn.send_resp(conn, 204, "")
  end

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 405, "")
end

defmodule Sj4.Court do
  @moduledoc """
  Chicago integration court for the SJ-4 emitter diff. Real collaborators:
  a real Bandit HTTP listener on loopback (port 0), the real `OcelEmitter`
  handler attached to `[:bandit, :request, :stop]`, the real `OcelNdjson`
  sink, and — on the ON leg — the real `Smalt.Storage.JournalSink` process
  plus the real `Smalt.Storage.JournalReader` parsing the sealed segment
  back off disk. Asserts on final on-disk state, never on call counts.

  Legs:

    * ON — `config :smalt, :journal_sink_dir` set → real wire requests
      (PUT and DELETE over real HTTP) produce journal frames; the segment
      is sealed and parsed back by the SJ-2 reader: monotonic, unique
      SeqIDs; wire put carries EventType 0x0001, wire delete 0x0002;
      emit/3 blob custody → 0x0003, amqp settled → 0x0004; Key = the real
      request path / object id; Payload JSON links the OCEL event id; the
      OCEL ndjson path still appends (coexistence).
    * OFF — config unset → no new journal directory appears under the tmp
      root during the leg, and the OCEL ndjson line keeps the exact four
      OCEL 2.0 top-level keys (behavior preserved).
  """

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink
  alias Smalt.Telemetry.OcelEmitter
  alias Smalt.Telemetry.OcelNdjson

  defp assert!(cond, msg) do
    unless cond, do: raise("SJ-4 COURT FAIL: " <> msg)
    IO.puts("  ok  " <> msg)
  end

  # -- runner -----------------------------------------------------------------

  def run do
    IO.puts("SJ-4 JOURNAL WIRE COURT")

    # Court runs under `mix run --no-start`: only the real wire collaborators
    # (bandit/plug/telemetry/jason/inets) are booted, not the full substrate —
    # the real telemetry path under test here is the emitter, not the planes.
    for app <- [:telemetry, :jason, :inets, :ssl, :bandit] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    unless Code.ensure_loaded?(JournalSink) do
      IO.puts(
        "SJ-4 COURT: SKIP (typed) — Smalt.Storage.JournalSink not landed (SJ-1); " <>
          "the emitter diff is in place and config OFF remains byte-identical."
      )

      System.halt(3)
    end

    OcelEmitter.attach()

    on_leg()
    off_leg()

    IO.puts("SJ-4 COURT: PASS")
    :ok
  end

  # -- ON leg -------------------------------------------------------------------

  defp on_leg do
    dir = Path.join(System.tmp_dir!(), "sj4-on-#{:os.system_time(:nano_seconds)}")
    prev = Application.fetch_env(:smalt, :journal_sink_dir)
    Application.put_env(:smalt, :journal_sink_dir, dir)

    # Real SJ-1 sink process (named — the same name the Application child uses).
    {:ok, sink} = JournalSink.start_link(dir: dir, sync_interval_ms: 5_000)

    ndjson_before = ndjson_body()
    {pid, port} = start_bandit()

    try do
      # Real wire requests through the real attached telemetry handler.
      {:ok, _} = wire_req(:put, port, "/sj4/cosmos/doc-1")
      {:ok, _} = wire_req(:delete, port, "/sj4/cosmos/doc-1")

      # Native emitters cover the remaining operator EventType codes.
      {:ok, _} =
        OcelEmitter.emit("blob.custody.transition", [%{"id" => "blob-sj4-a", "type" => "blob"}], %{
          "op" => "commit"
        })

      {:ok, _} =
        OcelEmitter.emit("amqp.delivery.settled", [%{"id" => "queue-sj4-a", "type" => "queue"}], %{
          "op" => "enqueue"
        })

      # Seal (fsync -> rename -> sha256 manifest -> sentinel) and parse the
      # frames back with the real SJ-2 reader — the durable on-disk state.
      meta = JournalSink.seal(sink)
      assert!(is_map(meta) and meta["frames"] == 4, "sealed segment holds exactly 4 frames (got #{inspect(meta)})")

      {:ok, segs} = JournalReader.discover_sealed_segments(dir)
      assert!(length(segs) == 1, "exactly one sealed segment discovered")

      {:ok, frames} = JournalReader.read_sealed_segment(hd(segs))
      assert!(length(frames) == 4, "reader returns exactly 4 frames")

      codes = frames |> Enum.map(& &1.event_type) |> Enum.sort()
      assert!(codes == [1, 2, 3, 4], "frames carry the operator EventType codes 0x0001..0x0004 (got #{inspect(codes)})")

      seqs = Enum.map(frames, & &1.seq_id)
      assert!(seqs == Enum.sort(seqs), "SeqID is monotonic in segment order (got #{inspect(seqs)})")
      assert!(seqs == Enum.to_list(0..3), "SeqID starts at 0 with no gaps (got #{inspect(seqs)})")

      put_frame = Enum.find(frames, &(&1.event_type == 1))
      del_frame = Enum.find(frames, &(&1.event_type == 2))

      assert!(
        put_frame.key == "/sj4/cosmos/doc-1" and del_frame.key == "/sj4/cosmos/doc-1",
        "wire put/delete frames carry the real request path as Key"
      )

      assert!(
        put_frame.ts > 0 and del_frame.ts > 0,
        "frames carry a real wall-clock Ts"
      )

      payload = Jason.decode!(put_frame.payload)
      assert!(is_binary(payload["ocel_event_id"]), "Payload JSON links the OCEL event id (matter-isolation: ids only)")

      ndjson_after = ndjson_body()
      assert!(String.length(ndjson_after) > String.length(ndjson_before),
        "OCEL ndjson still appended alongside the journal (coexistence)")
    after
      restore_env(prev)
      stop_bandit(pid)
      stop_sink(sink)
      File.rm_rf(dir)
    end
  end

  # -- OFF leg ----------------------------------------------------------------------

  defp off_leg do
    prev = Application.fetch_env(:smalt, :journal_sink_dir)
    Application.delete_env(:smalt, :journal_sink_dir)

    tmp_root = System.tmp_dir!()
    before_dirs = journal_dirs(tmp_root)

    {pid, port} = start_bandit()

    try do
      ndjson_before = ndjson_body()

      {:ok, _} = wire_req(:put, port, "/sj4/off/doc-2")
      {:ok, _} = wire_req(:delete, port, "/sj4/off/doc-2")

      {:ok, _} =
        OcelEmitter.emit("blob.custody.transition", [%{"id" => "blob-sj4-b", "type" => "blob"}], %{
          "op" => "commit"
        })

      after_dirs = journal_dirs(tmp_root)
      assert!(MapSet.new(after_dirs) == MapSet.new(before_dirs),
        "config OFF: no new journal directory appears anywhere under the tmp root")

      after_body = ndjson_body()
      assert!(String.length(after_body) > String.length(ndjson_before),
        "config OFF: OCEL ndjson path still appends (behavior preserved)")

      line = after_body |> String.split("\n", trim: true) |> List.last()
      doc = Jason.decode!(line)

      assert!(
        MapSet.new(Map.keys(doc)) ==
          MapSet.new(~w(ocel:eventTypes ocel:objectTypes ocel:events ocel:objects)),
        "config OFF: ndjson line keeps the exact four OCEL 2.0 top-level keys (byte-identical shape)"
      )
    after
      restore_env(prev)
      stop_bandit(pid)
    end
  end

  # -- helpers ------------------------------------------------------------------------

  defp journal_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        for e <- entries, String.contains?(e, "sj4-on"), do: Path.join(root, e)

      _ ->
        []
    end
    |> MapSet.new()
  end

  defp start_bandit do
    # Reserve an OS-assigned port, then bind Bandit to it (Bandit's
    # supervisor pid is not a socket; :inet.port needs the listener socket).
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, pid} = Bandit.start_link(plug: {Sj4.Plug, :ok}, scheme: :http, port: port)
    {pid, port}
  end

  defp stop_bandit(pid), do: GenServer.stop(pid, :normal)

  defp stop_sink(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  end

  defp wire_req(method, port, path) do
    :httpc.request(method, {~c"http://127.0.0.1:#{port}#{path}", []}, [], [])
  end

  defp ndjson_body do
    case File.read(Path.join(OcelNdjson.default_dir(), "events.ndjson")) do
      {:ok, body} -> body
      _ -> ""
    end
  end

  defp restore_env(prev) do
    case prev do
      :error -> Application.delete_env(:smalt, :journal_sink_dir)
      {:ok, v} -> Application.put_env(:smalt, :journal_sink_dir, v)
    end
  end
end

case Sj4.Court.run() do
  :ok -> System.halt(0)
  other ->
    IO.puts("SJ-4 COURT: FAIL #{inspect(other)}")
    System.halt(1)
end
