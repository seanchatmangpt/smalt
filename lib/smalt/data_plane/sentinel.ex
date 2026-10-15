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
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    existing =
      Store.list_prefix(:smalt_sentinel_rows, row_prefix(dcr, stream))
      |> length()

    Store.put(:smalt_sentinel_streams, "#{dcr}/#{stream}", %{
      "stream" => stream,
      "dcr" => dcr,
      "last_ingest" => now
    })

    stored =
      rows
      |> Enum.with_index(existing + 1)
      |> Enum.map(fn {row, seq} ->
        row = augment(row || %{})
        Store.put(:smalt_sentinel_rows, row_key(dcr, stream, seq), row)
        {seq, row}
      end)

    _ = stored

    {:ok, 204, ""}
  end

  def ingest(_dcr, _stream, _rows, _other) do
    {:error, 400,
     %{"error" => %{"code" => "InvalidApiVersion", "message" => "api-version must be #{@api_version}"}}}
  end

  defp augment(row) do
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
    stored_rows = Store.list_prefix(:smalt_sentinel_rows, "#{to_string(workspace_id)}/")

    case kql_pipeline(kql) do
      nil ->
        take = parse_take(kql)
        rows = Enum.take(stored_rows, take)
        envelope(rows, nil)

      pipeline ->
        case KQL.run(stored_rows, pipeline) do
          {:ok, rows} -> envelope(rows, project_columns(pipeline))
          {:error, {_kind, msg}} -> {:error, 400, %{"error" => %{"code" => "BadQuery", "message" => msg}}}
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
           "columns" => Enum.map(columns, fn name -> %{"name" => name, "type" => column_type(rows, name)} end),
           "rows" => Enum.map(rows, fn row -> Enum.map(columns, &stringify(Map.get(row, &1))) end)
         }
       ]
     }}
  end

  # Real Log Analytics preserves the projected column order. Extract the
  # project column list (in order) from the pipeline text.
  defp project_columns(pipeline) do
    case Regex.run(~r/\bproject\s+(.+)$/i, pipeline) do
      [_, cols] ->
        cols
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        nil
    end
  end

  # Column types honor the value shape, like real KQL: integer -> "long",
  # float -> "real", boolean -> "bool", everything else (including nil and
  # mixed shapes) -> "string".
  defp column_type(rows, column) do
    rows
    |> Enum.map(&Map.get(&1, column))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "string"
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
  defp kql_pipeline(kql) do
    if Regex.match?(~r/\|\s*(where|order\s+by|project)\b/i, kql) do
      kql
      |> String.split("|", parts: 2)
      |> case do
        [_table, pipeline] -> "| " <> String.trim(pipeline)
        [pipeline] -> "| " <> String.trim(pipeline)
      end
    end
  end

  defp parse_take(kql) do
    case Regex.run(~r/\btake\s+(\d+)\b/i, kql) do
      [_, n] -> min(String.to_integer(n), @max_take)
      _ -> @max_take
    end
  end

  @base_columns ["TimeGenerated", "ledgerId", "tenantId", "subjectSha256", "eventId", "sha256Hash"]

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
