defmodule Smalt.Storage.JournalSink do
  @moduledoc """
  PROD-1 — append-only journal sink writer (durable WAL foundation).

  Frame wire format (big-endian, one self-delimiting frame per record):

      MAGIC  "SMAL"                    4 bytes
      FrameLen u32  — bytes following the FrameLen field:
                       SeqID(8) + Ts(8) + EventType(2) + TableID(2)
                       + KeyLen(4) + Key + PayloadLen(4) + Payload + CRC32(4)
      SeqID    u64  — monotonic, sink-wide, assigned by the sink
      Ts       s64  — wall-clock milliseconds (caller-supplied or now)
      EventType u16
      TableID  u16
      KeyLen   u32, Key (KeyLen bytes)
      PayloadLen u32, Payload (PayloadLen bytes)
      CRC32    u32  — over SeqID..Payload (everything between FrameLen and CRC)

  Layout on disk:

      <dir>/active/seg-<20-digit-seq>.journal          (open segment)
      <dir>/sealed/seg-....journal                     (renamed on seal)
      <dir>/sealed/seg-....journal.meta.json           (sha256 + frame stats)
      <dir>/sealed/<name>.seal                         (sentinel)
      <dir>/quarantine/                                (crash-window tails)

  Seal protocol (atomicity contract, SPOF-A3 fix): the open segment is
  fsynced and closed, then the `meta.json` manifest and the `.seal`
  sentinel are written BESIDE the segment in `active/` (staging), and only
  then is the triple renamed into `sealed/` — segment, manifest, sentinel
  LAST rename. Rename-atomicity now carries completeness: any crash inside
  the rename window leaves an incomplete triple in `sealed/`, which the
  reader classifies as a completeness failure and quarantines (typed,
  telemetry-emitted — never silent, never a boot wedge). A fully renamed
  triple in `sealed/` implies fsync + sha256 manifest + sentinel all
  happened; integrity failures (CRC/manifest) remain fail-closed.

  Degraded mode (SPOF-A1 fix): the sink never raises on File errors.
  Directory/open/write/sync/rename failures during init, continue, append,
  sync, or seal are caught, logged (Logger.error with path + reason),
  emitted as `[:smalt, :journal, :degraded]` telemetry, and the sink runs
  degraded — accepting-and-dropping appends (each drop logged + counted in
  `:status`), seal typed-refused — while a bounded `send_after` re-probe
  returns it to active mode when the volume returns (recovery emits
  `[:smalt, :journal, :recovered]`). A log sink's restart budget is never
  paid for by the request planes.

  Matter partitioning (BK-135r): `append_frame/6` accepts `:matter_scope`
  (validated binary). Scoped frames route to `<dir>/matter_<scope>/segments/`
  with their own active/sealed/quarantine lifecycle, per-scope SeqIDs, and
  per-scope degrade/quarantine semantics (identical SPOF-A1/A3 laws). The
  default (no-scope) path is byte-identical to the pre-BK-135r journal: same
  dirs, same segment names, same frame wire format. Cross-scope contamination
  is structurally unrepresentable: every scoped byte lives under
  `matter_<scope>/`, and the scope name is validated
  (`^[A-Za-z0-9][A-Za-z0-9._-]*$` — no path separators, no traversal).
  """

  use GenServer
  require Logger

  @default_ceiling 64 * 1024 * 1024
  @default_sync_ms 500
  @default_reprobe_ms 5_000

  # --- public API ---------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name) || __MODULE__)
  end

  @doc """
  Appends one frame. The sink assigns the monotonic SeqID; `ts` (ms epoch)
  defaults to real-time clock.
  In degraded mode the append is accepted-and-dropped: still `{:ok, seq_id}`,
  logged + counted, never a crash of the caller.
  """
  def append(sink, event_type, table_id, key, payload, ts \\ nil)
      when is_integer(event_type) and is_integer(table_id) do
    GenServer.call(sink, {:append, event_type, table_id, key, payload, ts})
  end

  @doc """
  Appends one frame, optionally matter-scoped (BK-135r). `opts[:matter_scope]`
  (validated binary) routes the frame to `<dir>/matter_<scope>/segments/` on
  the scope's own SeqID stream. `opts[:ts]` overrides the frame timestamp.
  Returns `{:ok, seq_id}` (accepted; in a degraded scope the append is
  accepted-and-dropped, logged + counted) or `{:error, {:bad_matter_scope,
  scope}}` for an invalid scope — a typed refusal, never a path-traversal
  write.
  """
  def append_frame(sink, event_type, table_id, key, payload, opts \\ [])
      when is_integer(event_type) and is_integer(table_id) do
    GenServer.call(
      sink,
      {:append_frame, event_type, table_id, key, payload, Keyword.get(opts, :ts),
       Keyword.get(opts, :matter_scope)}
    )
  end

  @doc """
  Filesystem root of a matter scope: `<dir>/matter_<scope>/segments/`. Public
  so the reader and the courts resolve the SAME path law (one scope-naming
  law, never two).
  """
  def matter_root(dir, scope) when is_binary(dir) and is_binary(scope),
    do: Path.join([dir, "matter_" <> scope, "segments"])

  @doc "Validates a matter scope name. `:ok` or `{:error, {:bad_matter_scope, scope}}`."
  def validate_scope(scope) when is_binary(scope) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, scope) do
      :ok
    else
      {:error, {:bad_matter_scope, scope}}
    end
  end

  def validate_scope(scope), do: {:error, {:bad_matter_scope, scope}}

  @doc """
  Seals the active segment: fsync -> manifest+sentinel staged beside the
  segment -> rename triple into sealed/. Returns the meta map, or
  `{:error, :degraded}` / `{:error, {:seal_failed, reason}}` — a typed
  refusal, never a raise. With `matter_scope:` the SCOPE's active segment is
  sealed under the scope's own root.
  """
  def seal(sink, opts \\ []) do
    case Keyword.get(opts, :matter_scope) do
      nil -> GenServer.call(sink, :seal)
      scope -> GenServer.call(sink, {:seal_scope, scope})
    end
  end

  @doc "fsync the active segment now. Typed error in degraded mode."
  def sync(sink) do
    GenServer.call(sink, :sync)
  end

  @doc """
  Current segment stats: `%{path, bytes, frames, next_seq, mode, dropped}`.
  `mode` is `:active` or `:degraded`; `dropped` counts accepted-and-dropped
  appends since this sink process started.
  """
  def status(sink) do
    GenServer.call(sink, :status)
  end

  @doc """
  Per-scope status (BK-135r): `%{root, path, bytes, frames, next_seq, mode,
  degraded_reason, dropped}` — same shape as `status/1` plus `root`.
  Invalid scope -> `{:error, {:bad_matter_scope, scope}}`.
  """
  def status(sink, opts) when is_list(opts) do
    case Keyword.get(opts, :matter_scope) do
      nil -> GenServer.call(sink, :status)
      scope -> GenServer.call(sink, {:status_scope, scope})
    end
  end

  # --- frame codec (public for the SJ-2 reader and courts) ----------------
  # Extracted verbatim to Smalt.Storage.JournalSink.FrameCodec (T10 tail
  # split, v26.10.29 r10d). Facade keeps the public surface unchanged.

  defdelegate frame_magic(), to: Smalt.Storage.JournalSink.FrameCodec

  defdelegate encode_frame(seq_id, ts, event_type, table_id, key, payload),
    to: Smalt.Storage.JournalSink.FrameCodec

  defdelegate decode_frame(bin), to: Smalt.Storage.JournalSink.FrameCodec

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(opts) do
    dir = Path.expand(Keyword.fetch!(opts, :dir))
    ceiling = Keyword.get(opts, :segment_ceiling, @default_ceiling)
    sync_ms = Keyword.get(opts, :sync_interval_ms, @default_sync_ms)
    reprobe_ms = Keyword.get(opts, :reprobe_ms, @default_reprobe_ms)

    base = %{
      dir: dir,
      ceiling: ceiling,
      sync_ms: sync_ms,
      reprobe_ms: reprobe_ms,
      io: nil,
      path: nil,
      bytes: 0,
      frames: 0,
      next_seq: 0,
      sealed_count: 0,
      mode: :active,
      degraded_reason: nil,
      dropped: 0,
      scopes: %{}
    }

    case ensure_dirs(dir) do
      :ok -> {:ok, base, {:continue, :open_segment}}
      {:error, reason} -> {:ok, degrade(base, {:mkdir, dir, reason})}
    end
  end

  @impl true
  def handle_continue(:open_segment, state), do: {:noreply, open_segment(state)}

  @impl true
  def handle_call({:append_frame, event_type, table_id, key, payload, ts, nil}, _from, state) do
    do_append(event_type, table_id, key, payload, ts, state)
  end

  def handle_call({:append_frame, event_type, table_id, key, payload, ts, scope}, _from, state)
      when is_binary(scope) do
    case validate_scope(scope) do
      :ok ->
        ts = ts || System.system_time(:millisecond)

        case scope_state(state, scope) do
          {:ok, sc} ->
            seq = sc.next_seq
            {frame, _size, _seq} = encode_frame(seq, ts, event_type, table_id, key, payload)
            {sc, size} = maybe_rotate_scope(sc, scope, state, byte_size(frame))

            if sc.mode == :degraded do
              scope_drop(sc, scope, "append dropped (degraded scope, reason=#{inspect(sc.degraded_reason)})")

              {:reply, {:ok, seq},
               %{state | scopes: Map.put(state.scopes, scope, %{sc | next_seq: seq + 1, dropped: sc.dropped + 1})}}

            else
              case :file.write(sc.io, frame) do
                :ok ->
                  sc = %{sc | bytes: sc.bytes + size, frames: sc.frames + 1, next_seq: seq + 1}
                  {:reply, {:ok, seq}, %{state | scopes: Map.put(state.scopes, scope, sc)}}

                {:error, reason} ->
                  sc = degrade_scope(sc, state.dir, scope, {:write, sc.path, reason})

                  {:reply, {:ok, seq},
                   %{state | scopes: Map.put(state.scopes, scope, %{sc | next_seq: seq + 1, dropped: sc.dropped + 1})}}
              end
            end
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # legacy append — unchanged semantics, body factored into do_append/6
  @impl true
  def handle_call({:append, event_type, table_id, key, payload, ts}, _from, state) do
    do_append(event_type, table_id, key, payload, ts, state)
  end

  @impl true
  def handle_call(:seal, _from, %{mode: :degraded} = state) do
    {:reply, {:error, :degraded}, state}
  end

  def handle_call(:seal, _from, state) do
    case do_seal(state) do
      {meta, state} when is_map(meta) ->
        {:reply, meta, state}

      {{:error, reason}, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:seal_scope, scope}, _from, state) when is_binary(scope) do
    case validate_scope(scope) do
      :ok ->
        sc = Map.get(state.scopes, scope, new_scope_state())

        case do_scope_seal(sc, state, scope) do
          {meta, sc} when is_map(meta) ->
            {:reply, meta, %{state | scopes: Map.put(state.scopes, scope, sc)}}

          # a scope opened but never appended to has no active segment to
          # seal — typed refusal, never a CaseClauseError crash of the sink
          {nil, sc} ->
            {:reply, {:error, :empty_segment}, %{state | scopes: Map.put(state.scopes, scope, sc)}}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | scopes: Map.put(state.scopes, scope, sc)}}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:status_scope, scope}, _from, state) when is_binary(scope) do
    case validate_scope(scope) do
      :ok ->
        sc = Map.get(state.scopes, scope, new_scope_state())

        {:reply,
         %{
           root: matter_root(state.dir, scope),
           path: sc.path,
           bytes: sc.bytes,
           frames: sc.frames,
           next_seq: sc.next_seq,
           mode: sc.mode,
           degraded_reason: sc.degraded_reason,
           dropped: sc.dropped
         }, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, do_sync(state), state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       path: state.path,
       bytes: state.bytes,
       frames: state.frames,
       next_seq: state.next_seq,
       mode: state.mode,
       degraded_reason: state.degraded_reason,
       dropped: state.dropped
     }, state}
  end
  defp do_append(event_type, table_id, key, payload, ts, state) do
    ts = ts || System.system_time(:millisecond)
    seq = state.next_seq
    {frame, size, _seq} = encode_frame(seq, ts, event_type, table_id, key, payload)

    # pre-write rotation: seal BEFORE the write when this frame would cross
    # the ceiling, so no sealed segment ever exceeds it
    {state, size} =
      if state.mode == :active and state.bytes > 0 and state.bytes + size > state.ceiling do
        case do_seal(state) do
          {meta, st} when is_map(meta) ->
            {st, byte_size(frame)}

          # SPOF-A1: do_seal already degraded the sink (io closed, reprobe
          # armed) — fall through to the degraded accept-and-drop path instead
          # of crashing mid-append
          {{:error, {:seal_failed, _detail}}, st} ->
            {st, byte_size(frame)}
        end
      else
        {state, size}
      end

    if state.mode == :degraded do
      drop(state, "append dropped (degraded, reason=#{inspect(state.degraded_reason)})")
      {:reply, {:ok, seq}, %{state | next_seq: seq + 1, dropped: state.dropped + 1}}
    else
      case :file.write(state.io, frame) do
        :ok ->
          state = %{
            state
            | bytes: state.bytes + size,
              frames: state.frames + 1,
              next_seq: seq + 1
          }

          {:reply, {:ok, seq}, state}

        {:error, reason} ->
          state = degrade(state, {:write, state.path, reason})
          {:reply, {:ok, seq}, %{state | next_seq: seq + 1, dropped: state.dropped + 1}}
      end
    end
  end

  @impl true
  def handle_info(:sync_tick, state) do
    do_sync(state)
    {:noreply, state}
  end

  def handle_info({:sync_tick_scope, scope}, state) when is_binary(scope) do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{io: io}} when not is_nil(io) ->
        case :file.datasync(io) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            sc0 = Map.fetch!(state.scopes, scope)

            sc =
              degrade_scope(sc0, state.dir, scope, {:sync, sc0.path, reason})

            {:noreply, %{state | scopes: Map.put(state.scopes, scope, sc)}}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:reprobe, %{mode: :active} = state), do: {:noreply, state}

  def handle_info({:reprobe, scope}, state) when is_binary(scope) do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{mode: :degraded} = sc} ->
        root = matter_root(state.dir, scope)

        with :ok <- ensure_dirs(root),
             {:ok, io} <-
               File.open(sc_candidate_path(state.dir, scope, sc), [:raw, :append, :binary]) do
          File.close(io)

          Logger.info(
            "Smalt.Storage.JournalSink: matter scope #{scope} recovered; " <>
              "resuming scoped journaling under #{root}"
          )

          :telemetry.execute([:smalt, :journal, :recovered], %{count: 1}, %{
            dir: root,
            scope: scope
          })

          {:noreply,
           %{state | scopes: Map.put(state.scopes, scope, open_scope_segment(sc, state.dir, scope, state.sync_ms))}}
        else
          _ ->
            Process.send_after(self(), {:reprobe, scope}, state.reprobe_ms)
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:reprobe, state) do
    case ensure_dirs(state.dir) do
      :ok ->
        case File.open(candidate_active_path(state), [:raw, :append, :binary]) do
          {:ok, io} ->
            File.close(io)

            Logger.info(
              "Smalt.Storage.JournalSink: volume returned; resuming active journaling under #{state.dir}"
            )

            :telemetry.execute([:smalt, :journal, :recovered], %{count: 1}, %{dir: state.dir})

            {:noreply, open_segment(%{state | mode: :active, degraded_reason: nil})}

          {:error, _reason} ->
            Process.send_after(self(), :reprobe, state.reprobe_ms)
            {:noreply, state}
        end

      {:error, _reason} ->
        Process.send_after(self(), :reprobe, state.reprobe_ms)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    do_sync(state)
    if is_pid(state.io), do: File.close(state.io)

    Enum.each(state.scopes, fn {_scope, sc} ->
      if is_pid(sc.io) do
        _ = :file.datasync(sc.io)
        File.close(sc.io)
      end
    end)

    :ok
  end

  # --- internals -----------------------------------------------------------

  defp ensure_dirs(dir) do
    with :ok <- File.mkdir_p(Path.join(dir, "active")),
         :ok <- File.mkdir_p(Path.join(dir, "sealed")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # --- matter scopes (BK-135r) ----------------------------------------------

  defp new_scope_state do
    %{io: nil, path: nil, bytes: 0, frames: 0, next_seq: 0, sealed_count: 0,
      mode: :active, degraded_reason: nil, dropped: 0, reprobe_ms: @default_reprobe_ms}
  end

  defp sc_candidate_path(dir, scope, sc),
    do: Path.join([matter_root(dir, scope), "active", new_seg_name(sc.next_seq)])

  defp scope_state(state, scope) do
    case Map.fetch(state.scopes, scope) do
      {:ok, sc} ->
        {:ok, sc}

      :error ->
        root = matter_root(state.dir, scope)

        case ensure_dirs(root) do
          :ok ->
            {:ok,
             open_scope_segment(
               %{new_scope_state() | reprobe_ms: state.reprobe_ms},
               state.dir,
               scope,
               state.sync_ms
             )}

          {:error, reason} ->
            {:ok, degrade_scope(new_scope_state(), state.dir, scope, {:mkdir, root, reason})}
        end
    end
  end

  defp open_scope_segment(sc, dir, scope, sync_ms) do
    path = sc_candidate_path(dir, scope, sc)

    case File.open(path, [:raw, :append, :binary]) do
      {:ok, io} ->
        Process.send_after(self(), {:sync_tick_scope, scope}, sync_ms)
        %{sc | io: io, path: path, bytes: 0, frames: 0, mode: :active, degraded_reason: nil}

      {:error, reason} ->
        degrade_scope(%{sc | path: path}, dir, scope, {:open, path, reason})
    end
  end

  defp candidate_active_path(state),
    do: Path.join([state.dir, "active", new_seg_name(state.next_seq)])

  defp open_segment(state) do
    path = candidate_active_path(state)

    case File.open(path, [:raw, :append, :binary]) do
      {:ok, io} ->
        Process.send_after(self(), :sync_tick, state.sync_ms)
        %{state | io: io, path: path, bytes: 0, frames: 0}

      {:error, reason} ->
        degrade(state, {:open, path, reason})
    end
  end

  defp do_sync(%{io: nil}), do: :ok

  defp do_sync(state) do
    case :file.datasync(state.io) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = degrade(state, {:sync, state.path, reason})
        {:error, reason}
    end
  end

  defp degrade(state, {what, path, reason} = detail) do
    if is_pid(state.io), do: File.close(state.io)

    Logger.error(
      "Smalt.Storage.JournalSink: entering DEGRADED mode (#{what}) path=#{path} reason=#{inspect(reason)}; " <>
        "appends accepted-and-dropped until the volume returns"
    )

    :telemetry.execute([:smalt, :journal, :degraded], %{count: 1}, %{
      dir: state.dir,
      op: what,
      path: path,
      reason: reason
    })

    Process.send_after(self(), :reprobe, state.reprobe_ms)
    %{state | mode: :degraded, io: nil, path: nil, degraded_reason: detail}
  end

  defp drop(state, msg),
    do: Logger.error("Smalt.Storage.JournalSink: #{msg} [dropped_total=#{state.dropped + 1}]")

  # fsync -> close -> manifest+sentinel staged beside the segment -> rename
  # triple into sealed/ (segment, manifest, sentinel LAST rename). The last
  # rename carries completeness.
  defp do_seal(%{io: nil, frames: 0} = state), do: {nil, state}

  defp do_seal(state) do
    result =
      try do
        :file.datasync(state.io)
        match?({:ok, _}, :file.position(state.io, :eof)) || :ok

        case File.close(state.io) do
          :ok -> :ok
          {:error, reason} -> throw({:close, state.path, reason})
        end

        seg_name = Path.basename(state.path)
        active_path = state.path
        staged_meta = Path.join([state.dir, "active", seg_name <> ".meta.json"])
        staged_seal = Path.join([state.dir, "active", seg_name <> ".seal"])

        bytes = File.stat!(active_path).size
        sha = sha256_file(active_path)

        meta = %{
          "segment" => seg_name,
          "bytes" => bytes,
          "frames" => state.frames,
          "first_seq" => state.next_seq - state.frames,
          "last_seq" => state.next_seq - 1,
          "sha256" => sha
        }

        with :ok <- File.write(staged_meta, Jason.encode!(meta)),
             :ok <- File.touch(staged_seal) do
          sealed_path = Path.join([state.dir, "sealed", seg_name])

          with :ok <- File.rename(active_path, sealed_path),
               :ok <-
                 File.rename(
                   staged_meta,
                   Path.join([state.dir, "sealed", seg_name <> ".meta.json"])
                 ),
               :ok <-
                 File.rename(staged_seal, Path.join([state.dir, "sealed", seg_name <> ".seal"])) do
            case File.open(candidate_active_path(state), [:raw, :append, :binary]) do
              {:ok, new_io} ->
                Process.send_after(self(), :sync_tick, state.sync_ms)

                {meta,
                 %{
                   state
                   | io: new_io,
                     path: candidate_active_path(state),
                     bytes: 0,
                     frames: 0,
                     sealed_count: state.sealed_count + 1
                 }}

              {:error, reason} ->
                {meta,
                 degrade(
                   %{
                     state
                     | io: nil,
                       path: nil,
                       bytes: 0,
                       frames: 0,
                       sealed_count: state.sealed_count + 1
                   },
                   {:open, candidate_active_path(state), reason}
                 )}
            end
          else
            {:error, reason} -> throw({:rename, sealed_path, reason})
          end
        else
          {:error, reason} -> throw({:stage, active_path, reason})
        end
      catch
        {step, path, reason} -> {:seal_error, {step, path, reason}}
      end

    case result do
      {meta, _state2} = ok when is_map(meta) ->
        ok

      {:seal_error, detail} ->
        {{:error, {:seal_failed, detail}}, degrade(state, detail)}
    end
  end

  defp new_seg_name(seq),
    do: "seg-" <> String.pad_leading(Integer.to_string(seq), 20, "0") <> ".journal"

  # --- matter scope internals (BK-135r, SPOF-A1/A3 laws mirrored) -----------

  # pre-write rotation, per scope — mirror of the legacy do_append rotation
  defp maybe_rotate_scope(sc, scope, state, size) do
    cond do
      sc.mode == :degraded ->
        {sc, size}

      sc.bytes > 0 and sc.bytes + size > state.ceiling ->
        case do_scope_seal(sc, state, scope) do
          {meta, st} when is_map(meta) ->
            {st, size}

          # SPOF-A1 mirror: do_scope_seal already degraded THIS scope only —
          # drop the frame, never crash the sink mid-append
          {{:error, {:seal_failed, _detail}}, st} ->
            {st, size}
        end

      true ->
        {sc, size}
    end
  end

  # SPOF-A1 mirror, scoped: never raise on File errors — log, telemetry,
  # accept-and-drop, bounded re-probe. Confined to ONE matter scope: other
  # scopes and the legacy journal keep journaling (isolation law, BK-135r).
  defp degrade_scope(sc, dir, scope, {what, path, reason} = detail) do
    if is_pid(sc.io), do: File.close(sc.io)
    root = matter_root(dir, scope)

    Logger.error(
      "Smalt.Storage.JournalSink: matter scope #{scope} entering DEGRADED mode (#{what}) " <>
        "path=#{path} reason=#{inspect(reason)}; scoped appends accepted-and-dropped until the volume returns"
    )

    :telemetry.execute([:smalt, :journal, :degraded], %{count: 1}, %{
      dir: root,
      scope: scope,
      op: what,
      path: path,
      reason: reason
    })

    Process.send_after(self(), {:reprobe, scope}, sc.reprobe_ms)

    %{sc | mode: :degraded, io: nil, path: nil, degraded_reason: detail}
  end

  defp scope_drop(sc, scope, msg),
    do:
      Logger.error(
        "Smalt.Storage.JournalSink: matter scope #{scope}: #{msg} [dropped_total=#{sc.dropped + 1}]"
      )

  # SPOF-A3 mirror, scoped: fsync -> close -> stage manifest+sentinel beside
  # the segment -> rename triple into <matter_root>/sealed/ (sentinel LAST).
  defp do_scope_seal(%{mode: :degraded} = _sc, _state, _scope), do: {:error, :degraded}

  defp do_scope_seal(%{io: nil, frames: 0} = sc, _state, _scope), do: {nil, sc}

  defp do_scope_seal(sc, state, scope) do
    root = matter_root(state.dir, scope)

    result =
      try do
        :file.datasync(sc.io)
        match?({:ok, _}, :file.position(sc.io, :eof)) || :ok

        case File.close(sc.io) do
          :ok -> :ok
          {:error, reason} -> throw({:close, sc.path, reason})
        end

        seg_name = Path.basename(sc.path)
        active_path = sc.path
        staged_meta = Path.join([root, "active", seg_name <> ".meta.json"])
        staged_seal = Path.join([root, "active", seg_name <> ".seal"])

        bytes = File.stat!(active_path).size
        sha = sha256_file(active_path)

        meta = %{
          "segment" => seg_name,
          "bytes" => bytes,
          "frames" => sc.frames,
          "first_seq" => sc.next_seq - sc.frames,
          "last_seq" => sc.next_seq - 1,
          "sha256" => sha
        }

        with :ok <- File.write(staged_meta, Jason.encode!(meta)),
             :ok <- File.touch(staged_seal) do
          sealed_path = Path.join([root, "sealed", seg_name])

          with :ok <- File.rename(active_path, sealed_path),
               :ok <-
                 File.rename(staged_meta, Path.join([root, "sealed", seg_name <> ".meta.json"])),
               :ok <-
                 File.rename(staged_seal, Path.join([root, "sealed", seg_name <> ".seal"])) do
            case File.open(sc_candidate_path(state.dir, scope, sc), [:raw, :append, :binary]) do
              {:ok, new_io} ->
                Process.send_after(self(), {:sync_tick_scope, scope}, state.sync_ms)

                {meta,
                 %{sc | io: new_io, path: sc_candidate_path(state.dir, scope, sc), bytes: 0,
                   frames: 0, sealed_count: sc.sealed_count + 1}}

              {:error, reason} ->
                {meta,
                 degrade_scope(
                   %{sc | io: nil, path: nil, bytes: 0, frames: 0,
                     sealed_count: sc.sealed_count + 1},
                   state.dir,
                   scope,
                   {:open, sc_candidate_path(state.dir, scope, sc), reason}
                 )}
            end
          else
            {:error, reason} -> throw({:rename, sealed_path, reason})
          end
        else
          {:error, reason} -> throw({:stage, active_path, reason})
        end
      catch
        {step, path, reason} -> {:seal_error, {step, path, reason}}
      end

    case result do
      {meta, _state2} = ok when is_map(meta) ->
        ok

      {:seal_error, detail} ->
        {{:error, {:seal_failed, detail}}, degrade_scope(sc, state.dir, scope, detail)}
    end
  end

  defp sha256_file(path) do
    Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
  end
end
