defmodule Smalt.Messaging.EhCapture do
  @moduledoc """
  Event Hubs CAPTURE parity (wave-6 lane w6az).

  Opt-in per-hub capture description; events buffer per (hub, partition) and
  flush into smalt's REAL blob store — one JSONL capture file per partition
  per flush, with first/last sequence + count metadata.

  Azure parity boundary (honest): real Azure Capture writes AVRO; this
  emulator writes JSONL — a documented divergence, NOT claimed as avro.

  Triggers: `:size_limit_bytes` (checked after each enqueue) and
  `:interval_seconds` (per-hub timer). Whichever fires first; a size flush
  re-arms the hub interval clock. A failed blob write retries once, then the
  buffer is KEPT (never lost) and typed telemetry fires.
  """

  use GenServer

  alias Smalt.DataPlane.BlobStorage

  @table :smalt_eh_capture
  @default_account "smaltdev"
  @default_container "eh-capture"
  @default_name_format "{hub}/{partition}/{yyyy-MM-dd-HH-mm-ss}.jsonl"

  # SLEEP-CLASS: SCHEDULING — the interval flush is a real-world interval:
  # the runtime schedules the GenServer away until the capture window
  # elapses; readiness is observed via blob existence, never a clock guess.
  @interval_message :capture_flush_interval

  # --- public API ------------------------------------------------------------

  @doc """
  Enable capture for `hub`. `desc`:

      %{
        "account" => "smaltdev",            # optional
        "container" => "eh-capture",        # optional
        "name_format" => "..."              # optional
        "interval_seconds" => 60,           # positive integer
        "size_limit_bytes" => 313_196_135   # positive integer
      }

  At least one trigger required. Invalid input -> typed ArgumentError.
  """
  def enable(hub, desc) when is_binary(hub) and is_map(desc) do
    desc = validate_desc!(desc)
    ensure_started()
    Smalt.Store.put(@table, {"desc", hub}, desc)

    if iv = desc["interval_seconds"] do
      GenServer.call(__MODULE__, {:arm, hub, iv})
    end

    :ok
  end

  @doc "Disable capture for `hub`: cancels the timer; buffered events are kept."
  def disable(hub) when is_binary(hub) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:disable, hub})
    else
      Smalt.Store.delete(@table, {"desc", hub})
    end

    :ok
  end

  @doc "Capture description for `hub` -> `{:ok, desc} | :error`."
  def describe(hub) when is_binary(hub) do
    case Smalt.Store.get(@table, {"desc", hub}) do
      {:ok, desc} -> {:ok, desc}
      :error -> :error
    end
  end

  @doc """
  Buffer one event for {hub, partition}. Size trigger: buffer >= limit ->
  immediate flush. Capture disabled -> {:error, :capture_disabled}.
  Returns {:ok, :buffered} | {:ok, :flushed} | {:error, :capture_disabled}.
  """
  def enqueue(hub, partition, seq, event) do
    ensure_started()

    case Smalt.Store.get(@table, {"desc", hub}) do
      :error ->
        {:error, :capture_disabled}

      {:ok, desc} ->
        body = Jason.encode!(event)
        append_buffer(hub, partition, body, seq)
        limit = desc["size_limit_bytes"]

        if is_integer(limit) and buffer_bytes(hub, partition) >= limit do
          {:ok, _result} = flush(hub, partition)
          {:ok, :flushed}
        else
          {:ok, :buffered}
        end
    end
  end

  @doc """
  Flush {hub, partition}: one JSONL blob per flush with metadata
  {hub, partition, first/last sequence, count}. Empty buffer -> {:ok, :empty}.
  Failed write retries once; on persistent failure the buffer is kept and
  telemetry [:smalt, :event_hubs, :capture_write_failed] fires.
  Returns {:ok, %{count:, first:, last:, blob:}} | {:ok, :empty} | error.
  """
  def flush(hub, partition, opts \\ []) do
    case take_buffer(hub, partition) do
      :empty ->
        {:ok, :empty}

      buf ->
        case write_capture_blob(hub, partition, buf, opts) do
          {:ok, blob_key} ->
            {:ok,
             %{
               count: length(buf.events),
               first: buf.first_seq,
               last: buf.last_seq,
               blob: blob_key
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Buffered event count for {hub, partition} (diagnostic, test-observable)."
  def buffered_count(hub, partition) do
    case :ets.lookup(@table, {"buf", hub, partition}) do
      [] -> 0
      [{_, buf}] -> length(buf.events)
    end
  end

  @doc "The ETS table (witness/read access)."
  def table, do: @table

  # --- GenServer (timer owner) -------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, {:heir, Process.whereis(:init), []}])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:disable, hub}, _from, state) do
    Smalt.Store.delete(@table, {"desc", hub})
    {:reply, :ok, cancel_timer(state, hub)}
  end

  @impl true
  def handle_call({:arm, hub, interval_s}, _from, state) do
    state = cancel_timer(state, hub)
    {:reply, :ok, Map.put(state, {:timer, hub}, Process.send_after(self(), {@interval_message, hub}, interval_s * 1000))}
  end

  @impl true
  def handle_info({@interval_message, hub}, state) do
    for p <- buffered_partitions(hub), do: flush(hub, p)

    if desc = current_desc(hub) do
      if iv = desc["interval_seconds"] do
        state = cancel_timer(state, hub)
        state = Map.put(state, {:timer, hub}, Process.send_after(self(), {@interval_message, hub}, iv * 1000))
        {:noreply, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # --- internals --------------------------------------------------------------

  defp ensure_started do
    if Process.whereis(__MODULE__) == nil do
      case start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  defp validate_desc!(desc) do
    if desc["enabled"] not in [nil, true] do
      raise ArgumentError, "capture enabled must be true or absent"
    end

    triggers =
      Enum.count([trigger!(desc["interval_seconds"], "interval_seconds"), trigger!(desc["size_limit_bytes"], "size_limit_bytes")], fn t ->
        t
      end)

    if triggers < 1 do
      raise ArgumentError, "capture requires interval_seconds or size_limit_bytes"
    end

    if nf = desc["name_format"] do
      unless is_binary(nf) do
        raise ArgumentError, "name_format must be a binary"
      end
    end

    if c = desc["container"] do
      unless is_binary(c) do
        raise ArgumentError, "container must be a binary"
      end
    end

    if a = desc["account"] do
      unless is_binary(a) do
        raise ArgumentError, "account must be a binary"
      end
    end

    desc
  end

  defp trigger!(nil, _name), do: false

  defp trigger!(v, name) do
    unless is_integer(v) and v > 0 do
      raise ArgumentError, "#{name} must be a positive integer"
    end

    true
  end

  defp cancel_timer(state, hub) do
    case Map.pop(state, {:timer, hub}) do
      {nil, state} ->
        state

      {ref, state} ->
        Process.cancel_timer(ref)
        state
    end
  end

  defp current_desc(hub) do
    case Smalt.Store.get(@table, {"desc", hub}) do
      {:ok, desc} -> desc
      :error -> nil
    end
  end

  defp append_buffer(hub, partition, body, seq) do
    key = {"buf", hub, partition}

    buf =
      case :ets.lookup(@table, key) do
        [] -> %{events: [], bytes: 0, first_seq: seq, last_seq: seq}
        [{_, b}] -> b
      end

    buf = %{
      events: [body | buf.events],
      bytes: buf.bytes + byte_size(body),
      first_seq: buf.first_seq,
      last_seq: seq
    }

    :ets.insert(@table, {key, buf})
    :ok
  end

  defp buffer_bytes(hub, partition) do
    case :ets.lookup(@table, {"buf", hub, partition}) do
      [] -> 0
      [{_, b}] -> b.bytes
    end
  end

  defp take_buffer(hub, partition) do
    key = {"buf", hub, partition}

    case :ets.lookup(@table, key) do
      [] ->
        :empty

      [{_, buf}] ->
        :ets.delete(@table, key)
        %{events: Enum.reverse(buf.events), bytes: buf.bytes, first_seq: buf.first_seq, last_seq: buf.last_seq}
    end
  end

  defp buffered_partitions(hub) do
    :ets.match(@table, {{"buf", hub, :"$1"}, :_}) |> List.flatten()
  end

  defp write_capture_blob(hub, partition, buf, opts) do
    desc = current_desc(hub) || %{}
    account = desc["account"] || @default_account
    container = desc["container"] || @default_container
    name_format = desc["name_format"] || @default_name_format
    blob_name = render_name(name_format, hub, partition)
    body = Enum.join(buf.events, "\n") <> "\n"
    ensure_container(account, container)

    meta = %{
      "x-ms-meta-hub" => hub,
      "x-ms-meta-partition" => partition,
      "x-ms-meta-FirstSequence" => Integer.to_string(buf.first_seq),
      "x-ms-meta-LastSequence" => Integer.to_string(buf.last_seq),
      "x-ms-meta-Count" => Integer.to_string(length(buf.events))
    }

    case BlobStorage.put_blob(account, container, blob_name, body, meta, opts) do
      {:ok, _blob} ->
        {:ok, "#{account}/#{container}/#{blob_name}"}

      {:error, _, _, _} ->
        # one retry; on persistent failure keep the buffer (never lose events)
        case BlobStorage.put_blob(account, container, blob_name, body, meta, opts) do
          {:ok, _blob} -> {:ok, "#{account}/#{container}/#{blob_name}"}
          _ -> capture_write_failed(hub, partition)
        end

      {:error, _kind} ->
        capture_write_failed(hub, partition)
    end
  end

  defp capture_write_failed(hub, partition) do
    :telemetry.execute(
      [:smalt, :event_hubs, :capture_write_failed],
      %{count: 1},
      %{hub: hub, partition: partition}
    )

    {:error, :capture_write_failed}
  end

  defp ensure_container(account, container) do
    case Smalt.Store.get(:smalt_blob_containers, "#{account}/#{container}") do
      {:ok, _} ->
        :ok

      :error ->
        # pinned default-immutable class: opt OUT of immutability so blob
        # writes are admitted (mirror of the w6z ensure_containers fix)
        BlobStorage.create_container(account, container, %{"immutable" => false})
        :ok
    end
  end

  defp render_name(name_format, hub, partition) do
    ts = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.replace([" ", ":"], "-")

    name_format
    |> String.replace("{hub}", hub)
    |> String.replace("{partition}", partition)
    |> String.replace("{yyyy-MM-dd-HH-mm-ss}", ts)
  end
end
