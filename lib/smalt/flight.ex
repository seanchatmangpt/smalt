defmodule Smalt.Flight do
  @moduledoc """
  Flight-style shim: tickets and GetFlightInfo as JSON (no gRPC). Data is
  fetched via `do_get/2` which returns the Arrow IPC stream bytes.
  """
  alias Smalt.Flight.Arrow

  def ticket(settlement_ids) when is_list(settlement_ids),
    do: Base.url_encode64(JSON.encode!(%{"surface" => "flight", "ids" => settlement_ids}), padding: false)

  def get_flight_info(rows) when is_list(rows) do
    with :ok <- Enum.find_value(rows, :ok, fn r ->
           case Smalt.Flight.Row.validate(r) do
             :ok -> nil
             e -> e
           end
         end),
         {:ok, stream} <- Arrow.encode_stream(rows) do
      ids = Enum.map(rows, & &1.settlement_id)

      {:ok,
       JSON.encode!(%{
         "flight_descriptor" => %{"type" => "PATH", "path" => ["fnox", "settlements"]},
         "schema" => Arrow.columns(),
         "total_records" => length(rows),
         "total_bytes" => byte_size(stream),
         "row_bytes" => Smalt.Flight.Row.row_bytes(),
         "endpoint" => [%{"ticket" => ticket(ids), "location" => []}]
       })}
    end
  end

  @doc "Resolve a ticket against a row source (list of rows) and return the stream."
  def do_get(ticket, rows) do
    with {:ok, raw} <- Base.url_decode64(ticket, padding: false),
         %{"ids" => ids} <- JSON.decode!(raw) do
      Arrow.encode_stream(Enum.filter(rows, &(&1.settlement_id in ids)))
    else
      _ -> {:error, :bad_ticket}
    end
  end
end
