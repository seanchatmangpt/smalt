defmodule Smalt.Posh.Egress.EventLog do
  @moduledoc """
  Append-only JSONL event log for settled receipts (Starboard Out, POSH-002).

  File under the configured dir (default `tmp/posh/events.ndjson`), one JSON
  object per line, each entry chained by `prev_hash`: entry i's `prev_hash`
  equals entry i-1's `hash` (first entry's `prev_hash` is a 64-zero string).
  Append-only by law; never rewritten.
  """

  use GenServer

  @genesis_hash String.duplicate("0", 64)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Appends an entry; returns the full entry map including chained hash."
  def append(server \\ __MODULE__, entry) do
    GenServer.call(server, {:append, entry})
  end

  @doc "Reads all entries from disk (test/verification helper, real file read)."
  def read_all(dir) do
    path = Path.join(dir, "events.ndjson")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.reject(&(String.trim(&1) == ""))
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  @doc "Verifies prev-hash chaining of the on-disk log; `{:ok, n}` or `{:error, reason}`."
  def verify_chain(dir) do
    entries = read_all(dir)

    expected_prevs = [@genesis_hash | Enum.drop(Enum.map(entries, & &1["hash"]), -1)]

    chain_ok? =
      entries
      |> Enum.with_index()
      |> Enum.all?(fn {e, i} ->
        is_map_key(e, "prev_hash") and Enum.at(expected_prevs, i) == e["prev_hash"]
      end)

    if chain_ok?,
      do: {:ok, length(entries)},
      else: {:error, :chain_break}
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, "tmp/posh") |> Path.expand()
    File.mkdir_p!(dir)
    {:ok, %{dir: dir, prev_hash: @genesis_hash}}
  end

  @impl true
  def handle_call({:append, entry}, _from, state) do
    hash =
      :crypto.hash(:sha256, entry_serialization(entry) <> state.prev_hash)
      |> Base.encode16(case: :lower)

    record =
      entry
      |> Map.put(:prev_hash, state.prev_hash)
      |> Map.put(:hash, hash)
      |> Map.put(:emitted_at, DateTime.utc_now() |> DateTime.to_iso8601())

    File.open!(Path.join(state.dir, "events.ndjson"), [:append, :utf8], fn io ->
      IO.binwrite(io, Jason.encode!(record_to_jsonable(record)) <> "\n")
    end)

    {:reply, {:ok, record}, %{state | prev_hash: hash}}
  end

  defp entry_serialization(entry), do: :erlang.term_to_binary(entry)

  defp record_to_jsonable(record) do
    Map.new(record, fn {k, v} -> {to_string(k), jsonable(v)} end)
  end

  defp jsonable(v) when is_binary(v) or is_integer(v) or is_boolean(v) or is_float(v), do: v

  defp jsonable(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {to_string(k), jsonable(val)} end)
  end

  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)

  defp jsonable(other), do: Base.encode16(:erlang.term_to_binary(other), case: :lower)
end
