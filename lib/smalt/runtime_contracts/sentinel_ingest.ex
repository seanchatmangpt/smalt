defmodule Smalt.RuntimeContracts.SentinelIngest do
  @moduledoc """
  Sentinel / Log Analytics contract binding `Smalt.EgressRouter`'s Sentinel
  surface to its consumers.

  Fences, in-process, the wire invariants of the real DCR ingestion + KQL
  query surface:

    * ingest: 204 No Content + `x-ms-request-id`
    * ingest api-version gate: 400 `InvalidApiVersion` unless
      `api-version=2023-01-01`
    * ingest rows are queryable via `/v1/workspaces/:id/query` PrimaryResult
      envelope (tables[0].name, columns/rows)
    * row augmentation columns (`ledgerId`, `tenantId`, `subjectSha256`,
      `eventId`, `sha256Hash`) present on every stored row
    * KQL `| where` pipeline routes through the KQL engine (`where` filter
      respected)
    * parse error: 400 `BadQuery`

  Template source: ash-runtime-integration-contract-pack
  `templates/api_contract.ex.tmpl`, adapted (see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.Support

  @behaviour Smalt.RuntimeContracts.Contract

  @api_version "2023-01-01"

  @impl true
  def name, do: :sentinel_ingest

  @impl true
  def plane, do: :data_plane

  @impl true
  def check do
    Support.contract(:sentinel_ingest, [
      {:ingest_204_request_id, fn -> check_ingest() end},
      {:ingest_api_version_gate, fn -> check_api_version_gate() end},
      {:query_primary_result_envelope, fn -> check_query_envelope() end},
      {:row_augmentation_columns, fn -> check_augmentation() end},
      {:kql_where_filter, fn -> check_kql_where() end},
      {:bad_query_400, fn -> check_bad_query() end}
    ])
  end

  # ===========================================================================
  # checks
  # ===========================================================================

  defp check_ingest do
    dcr = unique("dcr-")
    stream = "Custom-Logs"
    resp = ingest(dcr, stream, [%{"msg" => "contract"}], @api_version)

    Support.assert_equal(resp.status, 204, "ingest must 204")

    Support.assert(
      is_binary(resp.headers["x-ms-request-id"]) and resp.headers["x-ms-request-id"] != "",
      "ingest carries x-ms-request-id"
    )
  end

  defp check_api_version_gate do
    resp = ingest(unique("dcr-"), "Custom-Logs", [%{"msg" => "x"}], "1999-01-01")
    Support.assert_equal(resp.status, 400, "wrong api-version -> 400")

    Support.assert_equal(
      json(resp.body)["error"]["code"],
      "InvalidApiVersion",
      "api-version gate code"
    )
  end

  defp check_query_envelope do
    dcr = unique("dcr-")
    ingest(dcr, "Custom-Logs", [%{"level" => "info", "msg" => "hello"}], @api_version)

    resp = query(dcr, "take 10")
    Support.assert_equal(resp.status, 200, "query status")

    tables = json(resp.body)["tables"]
    Support.assert(is_list(tables) and length(tables) >= 1, "PrimaryResult tables array")

    table = hd(tables)
    Support.assert_equal(table["name"], "PrimaryResult", "table name PrimaryResult")
    Support.assert(is_list(table["columns"]) and is_list(table["rows"]), "columns + rows arrays")
    envelope_columns(table)
  end

  defp envelope_columns(table) do
    cols = Enum.map(table["columns"], & &1["name"])

    for col <- ["ledgerId", "tenantId", "subjectSha256", "eventId", "sha256Hash"] do
      Support.assert(col in cols, "augmentation column #{col} in query envelope")
    end
  end

  defp check_augmentation do
    dcr = unique("dcr-")
    ingest(dcr, "Custom-Logs", [%{"level" => "warn", "subject" => "s1"}], @api_version)

    rows = query_rows(dcr, "take 10")

    Support.assert(length(rows) >= 1, "ingested row is queryable")

    row = row_map(table_columns(dcr), hd(rows))

    for col <- ["ledgerId", "tenantId", "subjectSha256", "eventId", "sha256Hash"] do
      v = Map.get(row, col)
      Support.assert(is_binary(v) and v != "", "augmented #{col} non-empty on stored row")
    end

    Support.assert_equal(String.length(row["sha256Hash"]), 64, "sha256Hash is 64 hex chars")
  end

  defp check_kql_where do
    dcr = unique("dcr-")
    ingest(dcr, "Custom-Logs", [%{"level" => "info"}, %{"level" => "error"}], @api_version)

    rows = query_rows(dcr, "| where level == 'error'")

    Support.assert(
      length(rows) == 1,
      "where filter selects only matching rows (got #{length(rows)})"
    )
  end

  defp check_bad_query do
    # Must still match the pipeline-routing regex (where/order by/project) so
    # the query reaches the KQL engine, then fail to parse there.
    resp = query(unique("dcr-"), "| where (((")
    Support.assert_equal(resp.status, 400, "parse error -> 400")
    Support.assert_equal(json(resp.body)["error"]["code"], "BadQuery", "BadQuery code")
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp ingest(dcr, stream, rows, av) do
    Support.dispatch(
      Smalt.EgressRouter,
      "post",
      "/dataCollectionRules/#{dcr}/streams/#{stream}?api-version=#{av}",
      body: Jason.encode!(rows)
    )
  end

  defp query(workspace, kql) do
    Support.dispatch(
      Smalt.EgressRouter,
      "post",
      "/v1/workspaces/#{workspace}/query?api-version=2023-01-01",
      body: Jason.encode!(%{"query" => kql})
    )
  end

  defp table_columns(workspace) do
    resp = query(workspace, "take 10")
    hd(json(resp.body)["tables"])["columns"] |> Enum.map(& &1["name"])
  end

  defp query_rows(workspace, kql) do
    resp = query(workspace, kql)
    # SHIM-COURT-adjacent fail-closed: never parse a non-200 envelope as a table.
    Support.assert_equal(resp.status, 200, "query status (#{kql})")

    case json(resp.body)["tables"] do
      [%{"rows" => rows} | _] when is_list(rows) ->
        rows

      other ->
        raise "query envelope missing tables/rows (status #{resp.status}): #{inspect(other)}"
    end
  end

  defp row_map(cols, values), do: Enum.zip(cols, values) |> Map.new()

  defp json(body), do: Jason.decode!(body)

  defp unique(prefix), do: prefix <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
end
