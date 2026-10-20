defmodule Smalt.DataPlane.Sentinel do
  @moduledoc """
  Azure Monitor Sentinel / Log Analytics data collection rule (DCR) ingestion and
  KQL query engine over the in-memory Store.

  Wire surface (route handlers in `EgressRouter` mount on 8443):
  - `POST /dataCollectionRules/:dcr/streams/:stream?api-version=2023-01-01` -> `ingest/4`
  - `POST /v1/workspaces/:id/query` -> `query/2`
  """

  alias Smalt.DataPlane.KQL
  alias Smalt.Store

  @api_version "2023-01-01"
  @max_take 101
  # Matches KQL's own query cap (kql.ex @max_query_length): enforced HERE at the
  # Sentinel entry point, BEFORE any literal-strip regex scan, so the legacy
  # (non-pipeline) path and an oversized query can never reach the scanner
  # (lane R175 E1/E3 — quadratic backtracking ReDoS + legacy-cap bypass).
  @max_query_length 2_000

  # ---------------------------------------------------------------------------
  # Ingest
  # ---------------------------------------------------------------------------

  @doc """
  Ingests `rows` into DCR `dcr` stream `stream`.

  Returns `{:ok, 204, ""}` (real Log Analytics answers 204 No Content with an
  `x-ms-request-id` header, added at the router seam) or
  `{:error, 400, body}` when the api-version is wrong.
  Each row is augmented with five string columns (when absent): `ledgerId`,
  `tenantId`, `subjectSha256`, `eventId`, `sha256Hash` (sha256 of canonical row JSON).
  """
  def ingest(dcr, stream, rows, @api_version) when is_binary(dcr) and is_binary(stream) do
    rows = List.wrap(rows)

    # Real Logs Ingestion admits an array of JSON objects only: a null or
    # scalar record is a request-level 400 with no partial insert (a nil row
    # previously slipped through as an empty record via `row || %{}`).
    cond do
      # Existence fence (lane event-planes lens-2 cycle 1, coordinator-authorized
      # pivot only): real Azure Logs Ingestion returns 404 for an ingest to a
      # never-created DCR; smalt's ingest path lazily materializes the stream.
      # The default keeps the emulated behavior (implicit create — a documented
      # divergence, pinned by test, C7-3a); when `:sentinel_dcr_strict` is set,
      # an ingest to a DCR with no prior stream state and no explicit creation
      # marker (`{:dcr_created, dcr}` in `:smalt_sentinel_streams`) is refused
      # with the 404-class envelope, proving the fix shape for the coordinated
      # C7-3a pivot (one `Application.put_env` flip).
      Application.get_env(:smalt, :sentinel_dcr_strict, false) and not dcr_exists?(dcr) ->
        {:error, 404,
         %{
           "error" => %{
             "code" => "DCRNotFound",
             "message" => "data collection rule #{dcr} not found"
           }
         }}

      Enum.all?(rows, &is_map/1) ->
        do_ingest(dcr, stream, rows)

      true ->
        {:error, 400,
         %{
           "error" => %{
             "code" => "InvalidData",
             "message" => "every record must be a JSON object"
           }
         }}
    end
  end

  def ingest(_dcr, _stream, _rows, _other) do
    {:error, 400,
     %{
       "error" => %{
         "code" => "InvalidApiVersion",
         "message" => "api-version must be #{@api_version}"
       }
     }}
  end

  # A DCR "exists" when it has prior stream state (any stream row under
  # "#{dcr}/") or an explicit creation marker.
  defp dcr_exists?(dcr) do
    match?({:ok, _}, Store.get(:smalt_sentinel_streams, {:dcr_created, dcr})) or
      Store.list_prefix(:smalt_sentinel_streams, "#{dcr}/") != []
  end

  # Debug-gated op timeline (lens-2 F-1 hunt): when
  # `Application.get_env(:smalt, :sentinel_forensic, false)` is set, every seq
  # bump and row put appends {System.monotonic_time(), op} to a public ETS
  # table :smalt_sentinel_forensic (created lazily here, owned by the first
  # caller — hunt-only, never enabled in normal runs).
  defp forensic_log(op) do
    if Application.get_env(:smalt, :sentinel_forensic, false) do
      table = :smalt_sentinel_forensic

      if :ets.info(table) == :undefined do
        try do
          :ets.new(table, [:named_table, :public, :ordered_set, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end
      end

      try do
        :ets.insert(table, {System.unique_integer([:monotonic, :positive]), op, self()})
      rescue
        # Owner churn: the first-caller-owned table can die between the info
        # check and this insert; the next op recreates it. Hunt-only tool.
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp do_ingest(dcr, stream, rows) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.put(:smalt_sentinel_streams, "#{dcr}/#{stream}", %{
      "stream" => stream,
      "dcr" => dcr,
      "last_ingest" => now
    })

    # Lane 19 (v26.10.14) item 2: materialize the DCR-creation marker the
    # `:sentinel_dcr_strict` fence pivots on (`dcr_exists?/1` checks
    # `{:dcr_created, dcr}` — previously only tests hand-seeded it, so strict
    # mode 404'd every DCR the lib itself created). Idempotent.
    Store.put(:smalt_sentinel_streams, {:dcr_created, dcr}, true)

    stored =
      rows
      |> Enum.map(fn row ->
        seq = next_row_seq(dcr, stream)
        row = augment(row, now)
        Store.put(:smalt_sentinel_rows, row_key(dcr, stream, seq), row)
        forensic_log({:put, dcr, stream, seq})
        {seq, row}
      end)

    _ = stored

    {:ok, 204, ""}
  end

  # Atomic per-stream row sequence, held as an integer counter row
  # `{:seq_counter, dcr, stream}` in the `:smalt_sentinel_streams` table.
  #
  # The entire check-seed-bump runs as ONE serialized `Store.next_seq/3`
  # handle_call (lens-3 F-1 root cause, see Store.next_seq/3 docs): the
  # previous caller-side init/check/CAS-seed/direct-bump shape let a
  # concurrent bump slip between the seed CAS's lookup and insert, clobbering
  # assigned seqs (duplicate row keys, last-write-wins collapse, final counter
  # short). seed_fun runs inside the Store GenServer only when the row is
  # missing and preserves "continue numbering across ingests" by counting
  # existing rows.
  defp next_row_seq(dcr, stream) do
    key = {:seq_counter, dcr, stream}

    seq =
      Store.next_seq(:smalt_sentinel_streams, key, fn ->
        Store.list_prefix(:smalt_sentinel_rows, row_prefix(dcr, stream))
        |> length()
      end)

    forensic_log({:bump, dcr, stream, seq})
    seq
  end

  # TimeGenerated: every DCR-ingested row carries a queryable timestamp — the
  # caller-supplied value wins; otherwise the ingest-time ISO8601 instant is
  # stamped so the KQL time functions (ago/between/datetime) always resolve
  # against real rows.
  defp augment(row, now) do
    canonical = canonical_json(row)
    hash = Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)

    subject = Map.get(row, "subject", canonical)

    eventId = Map.get(row, "eventId") || Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    row
    |> Map.put_new("ledgerId", ledger_id(canonical))
    |> Map.put_new("tenantId", tenant_id())
    |> Map.put_new("subjectSha256", sha256_hex(subject))
    |> Map.put("eventId", to_string(eventId))
    |> Map.put("sha256Hash", hash)
    |> Map.put_new("TimeGenerated", now)
  end

  defp ledger_id(canonical), do: "2.#{binary_part(sha256_hex(canonical), 0, 8)}"

  defp tenant_id, do: "00000000-0000-0000-0000-000000000000"

  defp sha256_hex(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  @doc false
  def canonical_json(row) when is_map(row) do
    inner =
      row
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> ~s("#{k}":#{canonical_json(v)}) end)
      |> Enum.join(",")

    "{#{inner}}"
  end

  def canonical_json(value), do: Jason.encode!(value)

  # ---------------------------------------------------------------------------
  # Table administration (per-stream tables: stats + retention)
  # ---------------------------------------------------------------------------

  @doc """
  Configures the per-stream table retention for `dcr`/`stream` in days.

  Stored on the stream meta row (`"retention_days"`) in `:smalt_sentinel_streams`.
  Returns `{:ok, days}`; `{:error, 400, ...}` when `days` is not a positive
  integer (real Log Analytics refuses non-positive retention with a typed 400).
  """
  def set_retention(dcr, stream, days) when is_binary(dcr) and is_binary(stream) do
    if is_integer(days) and days > 0 do
      meta =
        case Store.get(:smalt_sentinel_streams, "#{dcr}/#{stream}") do
          {:ok, meta} -> meta
          :error -> %{"stream" => stream, "dcr" => dcr}
        end

      Store.put(:smalt_sentinel_streams, "#{dcr}/#{stream}", Map.put(meta, "retention_days", days))
      {:ok, days}
    else
      {:error, 400,
       %{
         "error" => %{
           "code" => "InvalidRetention",
           "message" => "retentionDays must be a positive integer"
         }
       }}
    end
  end

  @doc """
  Per-table stats for every stream under `dcr`: row count plus oldest/newest
  `TimeGenerated` (ISO8601 strings, `nil` when the table has no parseable
  timestamps). Returns a map keyed `"{dcr}/{stream}"` -> `%{count, oldest,
  newest}`.
  """
  def table_stats(dcr) when is_binary(dcr) do
    for {stream, rows} <- stream_rows(dcr), into: %{} do
      stamps = timestamps(rows)

      {table_name(dcr, stream),
       %{
         count: length(rows),
         oldest: Enum.min(stamps, &<=/2, fn -> nil end),
         newest: Enum.max(stamps, &>=/2, fn -> nil end)
       }}
    end
  end

  @doc """
  Retention sweep over every stream table under `dcr`: deletes rows whose
  `TimeGenerated` is older than the table's configured `retention_days`
  (unset retention -> table untouched). Rows with no parseable timestamp are
  KEPT (fail-open). Emits typed telemetry
  `[:smalt, :sentinel, :retention_sweep]` with per-stream dropped counts.
  Returns a map keyed `"{dcr}/{stream}"` -> `%{dropped, kept}`.
  """
  def retention_sweep(dcr) when is_binary(dcr) do
    results =
      for {stream, rows} <- stream_rows(dcr), into: %{} do
        days = retention_days(dcr, stream)
        cutoff = cutoff_for(days)

        {dropped_count, kept_count} =
          if is_nil(cutoff) do
            {0, length(rows)}
          else
            {dropped, kept} = Enum.split_with(rows, fn row -> aged?(row, cutoff) end)
            {length(dropped), length(kept)}
          end

        drop_aged_rows(dcr, stream, cutoff)

        :telemetry.execute(
          [:smalt, :sentinel, :retention_sweep],
          %{dropped: dropped_count, kept: kept_count},
          %{dcr: dcr, stream: stream, retention_days: days || :unset}
        )

        {table_name(dcr, stream), %{dropped: dropped_count, kept: kept_count}}
      end

    results
  end

  defp stream_rows(dcr) do
    :smalt_sentinel_streams
    |> Store.list_prefix("#{dcr}/")
    |> Enum.map(& &1["stream"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn stream -> {stream, Store.list_prefix(:smalt_sentinel_rows, row_prefix(dcr, stream))} end)
  end

  defp retention_days(dcr, stream) do
    case Store.get(:smalt_sentinel_streams, "#{dcr}/#{stream}") do
      {:ok, %{"retention_days" => days}} when is_integer(days) and days > 0 -> days
      _ -> nil
    end
  end

  defp cutoff_for(nil), do: nil

  defp cutoff_for(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.to_iso8601()

  defp drop_aged_rows(_dcr, _stream, nil), do: :ok

  defp drop_aged_rows(dcr, stream, cutoff) do
    :smalt_sentinel_rows
    |> Store.prefix_keys(row_prefix(dcr, stream))
    |> Enum.each(fn key ->
      case Store.get(:smalt_sentinel_rows, key) do
        {:ok, row} ->
          if aged?(row, cutoff), do: Store.delete(:smalt_sentinel_rows, key)

        :error ->
          :ok
      end
    end)
  end

  defp aged?(row, cutoff) do
    case DateTime.from_iso8601(row["TimeGenerated"] || "") do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff_dt(cutoff)) == :lt
      _ -> false
    end
  end

  defp cutoff_dt(cutoff) do
    {:ok, dt, _} = DateTime.from_iso8601(cutoff)
    dt
  end

  defp timestamps(rows) do
    rows
    |> Enum.map(& &1["TimeGenerated"])
    |> Enum.reject(&is_nil/1)
  end

  defp table_name(dcr, stream), do: "#{dcr}/#{stream}"

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  KQL query for workspace `workspace_id`.

  Queries containing pipeline operators (`where`/`order by`/`project`, plus
  `take`) are routed through `Smalt.DataPlane.KQL.run/2` over the stored rows;
  plain `take N` strings keep the legacy behavior (capped at #{@max_take}).
  Returns a PrimaryResult envelope; empty result -> rows `[]`.
  Parse errors -> `{:error, 400, %{"error" => %{"code" => "BadQuery"}}}`.
  """
  def query(workspace_id, body) do
    kql = body |> Map.get("query", "") |> to_string()

    # Cap BEFORE any scan (strip_string_literals included): an oversized query
    # is refused with a typed 400 matching KQL.run's limit envelope, covering
    # both pipeline and legacy take paths (lane R175 E1/E3).
    if byte_size(kql) > @max_query_length do
      {:error, 400,
       %{
         "error" => %{
           "code" => "BadQuery",
           "message" => "query length exceeds #{@max_query_length}"
         }
       }}
    else
      do_query(workspace_id, kql)
    end
  end

  defp do_query(workspace_id, kql) do
    stored_rows = Store.list_prefix(:smalt_sentinel_rows, "#{to_string(workspace_id)}/")

    case kql_pipeline(kql) do
      :parse_error ->
        {:error, 400,
         %{
           "error" => %{
             "code" => "BadQuery",
             "message" =>
               "query uses a pipeline operator (where/order by/project/summarize/extend/sort) without a leading pipe"
           }
         }}

      nil ->
        take = parse_take(kql)
        rows = Enum.take(stored_rows, take)
        envelope(rows, nil)

      pipeline ->
        case KQL.run(stored_rows, pipeline) do
          {:ok, rows} ->
            envelope(rows, project_columns(pipeline))

          {:error, {_kind, msg}} ->
            {:error, 400, %{"error" => %{"code" => "BadQuery", "message" => msg}}}
        end
    end
  end

  defp envelope(rows, project_order) do
    columns =
      case project_order do
        nil -> columns_for(rows)
        cols -> cols
      end

    {:ok, 200,
     %{
       "tables" => [
         %{
           "name" => "PrimaryResult",
           "columns" =>
             Enum.map(columns, fn name -> %{"name" => name, "type" => column_type(rows, name)} end),
           "rows" => Enum.map(rows, fn row -> Enum.map(columns, &stringify(Map.get(row, &1))) end)
         }
       ]
     }}
  end

  # Real Log Analytics preserves the projected column order. Extract the
  # project column list (in order) from the pipeline text. Quoted string
  # literals are stripped first (lane R26 finding 1): `where msg == "project a"
  # | project lvl, n` previously matched the "project" inside the literal and
  # corrupted the column list. (KQL.run's own where/order scanning is
  # tokenizer-based and already string-aware; only this raw-regex scan was
  # literal-blind.)
  defp project_columns(pipeline) do
    # KD-COVERS: KD-22
    # SHIM-COURT lane R177: `([^|]+)` stops the scan at the next pipe
    # operator so `... | project a | where b` no longer swallows downstream
    # stages into the column list (quoting already stripped, so quoted
    # pipes are safe).
    case Regex.run(~r/\bproject\s+([^|]+)/i, strip_string_literals(pipeline)) do
      [_, cols] ->
        cols
        |> String.split(",")
        |> Enum.map(&project_out_name/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        nil
    end
  end

  # `project Alias = Col` outputs the ALIAS column (real Kusto naming); a bare
  # `project Col` outputs Col as-is.
  defp project_out_name(col) do
    case :binary.split(String.trim(col), "=") do
      [name, _expr] -> String.trim(name)
      [name] -> name
    end
  end

  # Blank single- and double-quoted KQL string literals so operator scans never
  # see operator keywords, pipes, or `take` inside literals. Backslash escapes
  # honored for both quote styles (matches the kql.ex tokenizer). Lane R126:
  # single-quoted literals previously reached the project regex / pipe split /
  # take scan raw, corrupting columns, pipeline split, and row caps.
  #
  # Lane R175 E1/E2: patterns rewritten linear — each `(?:...)*` alternation is
  # disjoint on the first byte (plain chars vs. backslash-escape, which consumes
  # ANY byte via `\\[\s\S]`, including newline), so no quadratic backtracking on
  # unterminated/pathological literals (ReDoS fix), and `\` + newline is now
  # INSIDE the literal (the tokenizer escapes the next BYTE), so a literal
  # containing `\` + newline continues to its real closing quote instead of
  # splitting — the engine and the strip scanner now agree.
  # SHIM-COURT target: blanking either quote style must stay load-bearing.
  defp strip_string_literals(text) do
    text
    |> then(&Regex.replace(~r/"(?:[^"\\\n\r]|\\[\s\S])*"/, &1, "\"\""))
    |> then(&Regex.replace(~r/'(?:[^'\\\n\r]|\\[\s\S])*'/, &1, "''"))
  end

  # Column types honor the value shape, like real KQL: integer -> "long",
  # float -> "real", boolean -> "bool", everything else (including nil and
  # mixed shapes) -> "string".
  defp column_type(rows, column) do
    rows
    |> Enum.map(&Map.get(&1, column))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        "string"

      values ->
        cond do
          Enum.all?(values, &is_integer/1) -> "long"
          Enum.all?(values, &is_float/1) -> "real"
          Enum.all?(values, &is_boolean/1) -> "bool"
          true -> "string"
        end
    end
  end

  # Routes to the KQL engine only when a filtering/sorting/projection operator is
  # present; plain `take N` strings keep legacy behavior. The leading table name
  # ("Custom-Logs") is stripped — the engine runs over the stored rows directly.
  #
  # Lane R26 finding 2: a predicate-only query without a leading pipe
  # (`where lvl == "a"`) previously fell through to the legacy take path,
  # silently discarding the filter and returning ALL rows with 200. Bare
  # operator keywords (string literals stripped first) without a leading pipe
  # are a parse error -> typed 400 BadQuery envelope.
  # The engine-routed operator set is (where|order by|project|summarize|extend|
  # sort|take): bare operator keywords without a leading pipe are a typed 400.
  # Plain `take N` strings keep legacy behavior (no pipe needed).
  defp kql_pipeline(kql) do
    # Scans (pipe/operator detection, split point) run on the literal-stripped
    # text so pipes/keywords inside literals are invisible (lane R126 exploit 2);
    # the pipeline text handed to KQL.run is sliced from the ORIGINAL kql at the
    # same offset so execution still sees real literals.
    stripped = strip_string_literals(kql)

    cond do
      Regex.match?(
        ~r/\|\s*(where|order\s+by|project|summarize|extend|sort|take)\b/i,
        stripped
      ) ->
        case :binary.match(stripped, "|") do
          {index, _length} ->
            # Slice from the ORIGINAL kql (execution must see real literals);
            # the slice already begins with the pipe itself.
            String.slice(kql, index..-1//1) |> String.trim()

          # Unreachable: the stripped text matched a pipe above.
          :nomatch ->
            String.trim(kql)
        end

      # Bare operator, no leading pipe (quoting-aware scan). `take` is
      # deliberately excluded — a bare `take N` keeps legacy behavior above.
      Regex.match?(
        ~r/(?:^|\s)(where|order\s+by|project|summarize|extend|sort)\b/i,
        stripped
      ) ->
        :parse_error

      true ->
        nil
    end
  end

  defp parse_take(kql) do
    # Literal-blind scan would cap rows on a `take` inside a string literal
    # (lane R126 exploit 3); scan the stripped text instead.
    case Regex.run(~r/\btake\s+(\d+)\b/i, strip_string_literals(kql)) do
      [_, n] -> min(String.to_integer(n), @max_take)
      _ -> @max_take
    end
  end

  @base_columns [
    "TimeGenerated",
    "ledgerId",
    "tenantId",
    "subjectSha256",
    "eventId",
    "sha256Hash"
  ]

  defp columns_for([]), do: @base_columns

  defp columns_for(rows) do
    rows
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stringify(nil), do: nil

  defp stringify(v) when is_binary(v), do: v

  defp stringify(v), do: to_string(v)

  defp row_prefix(dcr, stream), do: "#{dcr}/#{stream}/"

  defp row_key(dcr, stream, seq), do: "#{dcr}/#{stream}/#{pad(seq)}"

  defp pad(seq), do: String.pad_leading(to_string(seq), 20, "0")
end
