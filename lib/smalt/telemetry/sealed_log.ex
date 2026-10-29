defmodule Smalt.Telemetry.SealedLog do
  @moduledoc """
  Decoupled append-only sink for OCEL-class events: callers pay only a
  `GenServer.cast` on the emit path; the sink process owns encode + CRC32
  framing + file write. Durability is the sink's problem, not the caller's.

  ## Frame format (self-describing, CRC-guarded)

      <<len::32, `crc32::32`, payload::binary-size(len)>>

  * `crc32 = :erlang.crc32(payload)` — a flipped bit in a payload byte
  cannot validate; the reader returns a typed `{:crc_mismatch, offset}`.
  * The seal sentinel is an ordinary frame whose payload begins with the
  magic `"SMALT-SEALED:"`; an independent reader discovers it by scanning
  raw frames, never by asking the sink for state.

  ## Laws

  * Emit = cast. The caller-visible cost is the cast; encode/framing/write
  happen in the sink process.
  * Concurrent-safe: casts from any number of tasks serialize inside the
  sink; sink-received order is the lawful order for an append-only log.
  * `seal/1` is synchronous and owns the flush boundary: after `{:ok,
  count}` returns, every accepted event plus the sentinel are in the OS
  file. Post-seal casts are ignored (sealed log = immutable append law).
  * `read_frames/1` is PURE (no server contact, no process state): the
  independent reader runs in any process against the file alone.
  """

  use GenServer

  @magic "SMALT-SEALED:"
  @header_bytes 8

  @type frame :: %{offset: non_neg_integer(), payload: binary()}

  @doc "Seal sentinel magic prefix."
  @spec seal_magic() :: String.t()
  def seal_magic, do: @magic

  @doc "Frame header size in bytes."
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc """
  Starts the sink. Options:

    * `:path` — target log file (created; parent dirs made). Required.
    * `:name` — optional GenServer name (defaults to the module).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, path, name: name)
  end

  @doc """
  Emit one event: cast-only, returns `:ok` without ever touching the file
  in the caller's process. Payload is any term Jason can encode (a map
  with string keys is the lawful shape).
  """
  @spec emit(GenServer.server(), term()) :: :ok
  def emit(server \\ __MODULE__, payload), do: GenServer.cast(server, {:event, payload})

  @doc """
  Seal the log: flush boundary. Writes the sentinel frame and returns
  `{:ok, persisted_count}`. Post-seal emits are ignored by the sink.
  """
  @spec seal(GenServer.server()) :: {:ok, non_neg_integer()}
  def seal(server \\ __MODULE__), do: GenServer.call(server, :seal, 30_000)

  @doc "Sink-side persisted event count (excludes the sentinel)."
  @spec persisted(GenServer.server()) :: non_neg_integer()
  def persisted(server \\ __MODULE__), do: GenServer.call(server, :persisted)

  @doc """
  Pure independent reader. Reads the file, parses frames, validates every
  CRC32. Returns `{:ok, %{frames: frames, sentinel: payload | nil}}` where
  frames excludes the sentinel, or `{:error, {:crc_mismatch, offset}}` on
  any tampered byte. Runs in the caller's process with no server contact.
  """
  @spec read_frames(String.t()) ::
          {:ok, %{frames: [frame()], sentinel: binary() | nil}}
          | {:error, {:crc_mismatch, non_neg_integer()}}
  def read_frames(path) do
    bin = File.read!(path)
    walk(bin, 0, [], nil)
  catch
    {:crc, offset} -> {:error, {:crc_mismatch, offset}}
  end

  defp walk(<<>>, _offset, frames, sentinel),
    do: {:ok, %{frames: Enum.reverse(frames), sentinel: sentinel}}

  defp walk(bin, offset, frames, sentinel) do
    case bin do
      <<len::unsigned-integer-size(32), crc::unsigned-integer-size(32), rest::binary>> ->
        if byte_size(rest) < len, do: throw({:crc, offset})

        <<payload::binary-size(^len), tail::binary>> = rest

        if :erlang.crc32(payload) == crc do
          next = offset + @header_bytes + len

          if is_sentinel?(payload) do
            walk(tail, next, frames, %{offset: offset, payload: payload})
          else
            walk(tail, next, [%{offset: offset, payload: payload} | frames], sentinel)
          end
        else
          throw({:crc, offset})
        end

      _ ->
        # shorter than a header: typed truncation, fail closed
        throw({:crc, offset})
    end
  end

  defp is_sentinel?(<<@magic, _::binary>>), do: true
  defp is_sentinel?(_), do: false

  # -- GenServer callbacks (storage side) -----------------------------------

  @impl true
  def init(path) do
    :ok = File.mkdir_p(Path.dirname(path))

    case :file.open(path, [:append, :raw, :binary]) do
      {:ok, fd} -> {:ok, %{fd: fd, path: path, count: 0, sealed?: false}}
      {:error, reason} -> {:stop, {:file_open_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:event, _payload}, %{sealed?: true} = st), do: {:noreply, st}

  def handle_cast({:event, payload}, %{sealed?: false} = st) do
    line = Jason.encode!(payload)
    frame = <<byte_size(line)::unsigned-integer-size(32), :erlang.crc32(line)::unsigned-integer-size(32), line::binary>>
    :ok = :file.write(st.fd, frame)
    {:noreply, %{st | count: st.count + 1}}
  end

  @impl true
  def handle_call(:seal, _from, %{sealed?: true} = st), do: {:reply, {:ok, st.count}, st}

  def handle_call(:seal, _from, %{fd: fd, count: count, sealed?: false} = st) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    line = "#{@magic}#{stamp} events=#{count}"

    frame =
      <<byte_size(line)::unsigned-integer-size(32), :erlang.crc32(line)::unsigned-integer-size(32),
        line::binary>>

    :ok = :file.write(fd, frame)
    {:reply, {:ok, count}, %{st | sealed?: true}}
  end

  def handle_call(:persisted, _from, st), do: {:reply, st.count, st}
end
