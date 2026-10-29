defmodule Smalt.AppConfigRevisions do
  @moduledoc """
  Wave-6 lane w6ao - App Configuration revision history (Azure /revisions face).

  Every kv write on the appconfig plane records an immutable revision row
  (key, label, value, contentType, tags, etag, last_modified). Revisions are
  keyed by etag - never rewritten, only appended. `restore/2` takes a revision
  etag and re-materializes it as the current kv row with a FRESH etag (the
  revision row itself is immutable - history grows, never rewrites).

  ## Write-path seam (documented per lane contract)

  The egress kv_write lives inside the w6R router split (egress/AppConfig.ex,
  in-flight - no edits permitted under the wave-6 router hold). The seam is
  MODULE-LEVEL: `record/1` is the single hook the egress write path calls
  (AppConfigRevisions.record(record) right after the kv Store.put), and the
  one-line call-site + mount drafts are staged in tmp/w6ao_router_patch.txt
  for post-split application. Until applied, revisions are recorded for any
  write that goes through this module's `write/4`, which performs the
  Store.put + revision recording in the one lawful order.

  ## Table law

  :smalt_appconfig_revisions is module-owned ETS (:ordered_set keyed {etag,
  key, label}), created with the shadow-table heir law (3-tuple heir to
  Process.whereis(:init)); `ensure_table/0` is lazy + idempotent. Not a
  generated StoreTables entry - that file is mix smalt.gen replay-fenced,
  never hand-edited.
  """

  @table :smalt_appconfig_revisions

  @doc "Ensure the revisions table exists (idempotent, heir'd to init)."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :ordered_set,
        :public,
        :named_table,
        {:heir, Process.whereis(:init), []},
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  defp store_ready?, do: :ets.info(:smalt_appconfig) != :undefined

  @doc """
  Record a revision row from a kv record (the egress write-path hook).
  Idempotent per etag; a nil-etag record is refused (typed).
  Returns :ok | {:error, :invalid_record}.
  """
  @spec record(map()) :: :ok | {:error, :invalid_record}
  def record(%{"key" => key, "label" => label, "etag" => etag} = kv)
      when is_binary(key) and is_binary(label) and is_binary(etag) do
    ensure_table()

    row = {etag, key, label}

    rev = revision_row(kv) |> Map.put("seq", :erlang.unique_integer([:monotonic, :positive]))

    case :ets.insert_new(@table, {row, rev}) do
      true -> :ok
      false -> :ok
    end
  end

  def record(_), do: {:error, :invalid_record}

  @doc """
  The lawful write path: Store.put the kv record, then record its revision.
  Returns {:ok, record}. (Mirrors what the staged egress call-site does.)
  """
  @spec write(String.t(), String.t(), :error | {:ok, map()}, map()) :: {:ok, map()}
  def write(key, label, _existing, record) do
    Smalt.Store.put(:smalt_appconfig, {key, label}, record)
    record(record)
    {:ok, record}
  end

  @doc """
  List revisions. Filters (Azure /revisions parity):
    key:      glob (exact, or `*` prefix/suffix match; nil = all)
    label:    glob (same grammar; nil = all)
    end_time: POSIX seconds; revisions with last_modified <= end_time only
  Revisions render most-recent-first by {last_modified, etag}.
  """
  @spec list(keyword() | map()) :: [map()]
  def list(filters \\ %{}) do
    filters = Map.new(filters)
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.map(fn {_row, rev} -> rev end)
    |> Enum.filter(fn rev ->
      glob_match?(rev["key"], filters[:key] || filters["key"]) and
        glob_match?(rev["label"], filters[:label] || filters["label"]) and
        end_time_match?(rev["last_modified"], filters[:end_time] || filters["end_time"])
    end)
    |> Enum.sort_by(& &1["seq"], :desc)
  end

  @doc """
  Restore a revision by etag: re-materialize it as the current kv row with a
  FRESH etag (content restored, etag re-stamped), record the restored state as
  a new revision. Returns {:ok, restored_record} | {:error, :not_found} (404
  face: unknown revision etag) | {:error, :store_not_ready}.
  """
  @spec restore(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | :store_not_ready}
  def restore(revision_etag, opts \\ []) do
    ensure_table()

    found =
      :ets.tab2list(@table)
      |> Enum.find(fn {_row, rev} -> rev["etag"] == revision_etag end)

    case found do
      nil ->
        {:error, :not_found}

      {_row, rev} ->
        if store_ready?() do
          key = rev["key"]
          label = rev["label"]

          fresh_etag = quote_etag(key, label, rev["value"], rev["contentType"])

          restored = %{
            "key" => key,
            "label" => label,
            "value" => rev["value"],
            "contentType" => rev["contentType"],
            "tags" => rev["tags"] || %{},
            "locked" => false,
            "etag" => fresh_etag,
            "last_modified" => System.system_time(:second)
          }

          label_key = {key, label}
          Smalt.Store.put(:smalt_appconfig, label_key, restored)
          record(restored)

          if opts[:wire], do: {:ok, revision_wire(restored)}, else: {:ok, restored}
        else
          {:error, :store_not_ready}
        end
    end
  end

  @doc "Count of revision rows (witness/diagnostic)."
  @spec count() :: non_neg_integer()
  def count do
    ensure_table()
    :ets.info(@table, :size)
  end

  # --- internals -----------------------------------------------------------

  defp revision_row(kv) do
    %{
      "key" => kv["key"],
      "label" => kv["label"],
      "value" => kv["value"],
      "contentType" => kv["contentType"],
      "tags" => kv["tags"] || %{},
      "etag" => kv["etag"],
      "last_modified" => kv["last_modified"] || System.system_time(:second)
    }
  end

  defp quote_etag(key, label, value, ct) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({key, label, value, ct, System.system_time()}))
      |> Base.encode16()

    "\"" <> hash <> "\""
  end

  # Same glob grammar as the w6l kv faces: exact, or `*` prefix/suffix combo.
  defp glob_match?(_v, nil), do: true
  defp glob_match?(_v, "*"), do: true

  defp glob_match?(value, pattern) when is_binary(value) and is_binary(pattern) do
    case String.split(pattern, "*", parts: 2) do
      [exact] -> value == exact
      [prefix, ""] -> String.starts_with?(value, prefix)
      [prefix, suffix] -> String.starts_with?(value, prefix) and String.ends_with?(value, suffix)
    end
  end

  defp glob_match?(_non_binary, _pattern), do: false

  defp end_time_match?(_ts, nil), do: true

  defp end_time_match?(ts, end_time) when is_integer(ts) and is_integer(end_time),
    do: ts <= end_time

  defp end_time_match?(_ts, _bad), do: false

  @doc "Azure /revisions wire shape (items entry)."
  @spec revision_wire(map()) :: map()
  def revision_wire(rev) do
    %{
      "key" => rev["key"],
      "label" => rev["label"],
      "value" => rev["value"],
      "contentType" => rev["contentType"],
      "tags" => rev["tags"],
      "etag" => rev["etag"],
      "last_modified" => rev["last_modified"]
    }
  end
end
