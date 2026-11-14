defmodule Smalt.Azure.LogAnalytics do
  @moduledoc """
  Log Analytics parity gaps (mirrors arcus AX1 loganalytics): workspace-table
  listing/get and ingest-with-ack over the real `Smalt.DataPlane.Sentinel`
  row store. Tables are DCR streams (`"{dcr}/{stream}"`).
  """

  alias Smalt.DataPlane.Sentinel

  @api "2023-01-01"

  @spec ingest(binary, binary, list) :: {:ok, 204, binary} | {:error, 400, map}
  def ingest(dcr, stream, rows) when is_list(rows), do: Sentinel.ingest(dcr, stream, rows, @api)

  @spec list_tables(binary) :: {:ok, 200, map}
  def list_tables(dcr) do
    value =
      for {name, st} <- Enum.sort(Sentinel.table_stats(dcr)) do
        %{"name" => name, "properties" => %{"rowCount" => st.count}}
      end

    {:ok, 200, %{"value" => value}}
  end

  @spec get_table(binary, binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_table(dcr, stream) do
    key = dcr <> "/" <> stream

    case Map.fetch(Sentinel.table_stats(dcr), key) do
      {:ok, st} ->
        {:ok, 200,
         %{"name" => key,
           "properties" => %{"rowCount" => st.count, "oldest" => st.oldest, "newest" => st.newest}}}

      :error ->
        {:error, 404, %{"error" => %{"code" => "ResourceNotFound", "message" => key}}}
    end
  end
end
