defmodule Smalt.H08.RatesRouter do
  @moduledoc """
  H08 rates routes, forwarded from `Smalt.Rates.Http` (catch-all): NY Fed SOFR/EFFR
  `last/N` and `search` in the real markets-API shape, the SOFR curve and compounded average,
  and stateful ABS loan tapes.
  """
  use Plug.Router
  alias Smalt.H08.{AbsTape, SofrCurve}
  alias Smalt.Rates.NyFed

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  defp json(conn, s, body), do: conn |> put_resp_content_type("application/json") |> send_resp(s, Jason.encode!(body))
  defp bad(conn, msg), do: json(conn, 400, %{"error" => msg})

  defp series(conn, type) do
    # Shared by last/N and search; rows are newest first.
    %{"refRates" => rows} = NyFed.ref_rates(type)
    {conn, rows}
  end

  get "/api/rates/secured/sofr/last/:n" do
    last(conn, :sofr, n)
  end

  get "/api/rates/unsecured/effr/last/:n" do
    last(conn, :effr, n)
  end

  get "/api/rates/secured/sofr/search.json" do
    search(conn, :sofr)
  end

  get "/api/rates/unsecured/effr/search.json" do
    search(conn, :effr)
  end

  get "/h08/sofr/curve" do
    json(conn, 200, SofrCurve.curve())
  end

  get "/h08/sofr/average" do
    conn = fetch_query_params(conn)
    {s, e} = {conn.query_params["start"], conn.query_params["end"]}

    if is_date(s) and is_date(e) and s <= e do
      case SofrCurve.average(s, e) do
        {:ok, m} -> json(conn, 200, m)
        {:error, :no_data} -> json(conn, 404, %{"error" => "no_data"})
      end
    else
      bad(conn, "start and end must be ISO dates with start <= end")
    end
  end

  post "/h08/abs/tape" do
    p = conn.body_params

    with id when is_binary(id) and id != "" <- p["pool_id"],
         c when is_integer(c) and c > 0 <- p["principal_cents"],
         n when is_integer(n) and n > 0 and n <= 5000 <- p["n"],
         d when is_binary(d) <- p["as_of"],
         true <- is_date(d) do
      case AbsTape.store(AbsTape.build(id, c, n, d)) do
        {:ok, t} -> json(conn, 201, t)
        {:error, :exists} -> json(conn, 409, %{"error" => "tape exists for pool_id"})
      end
    else
      _ -> json(conn, 422, %{"error" => "pool_id, principal_cents>0, 0<n<=5000, as_of ISO date required"})
    end
  end

  get "/h08/abs/tape/:pool_id" do
    case AbsTape.fetch(pool_id) do
      nil -> json(conn, 404, %{"error" => "not_found"})
      t -> json(conn, 200, t)
    end
  end

  match _ do
    json(conn, 404, %{"error" => "not_found"})
  end

  defp is_date(d), do: is_binary(d) and match?({:ok, _}, Date.from_iso8601(d))

  defp last(conn, type, file) do
    with [_, n] <- Regex.run(~r/\A(\d+)\.json\z/, file),
         {k, ""} <- Integer.parse(n),
         true <- k >= 1 do
      {conn, rows} = series(conn, type)
      json(conn, 200, %{"refRates" => Enum.take(rows, k)})
    else
      _ -> bad(conn, "last/N requires a positive integer N.json")
    end
  end

  defp search(conn, type) do
    conn = fetch_query_params(conn)
    {s, e} = {conn.query_params["startDate"], conn.query_params["endDate"]}

    if is_date(s) and (e == nil or is_date(e)) and (e == nil or s <= e) do
      {conn, rows} = series(conn, type)
      json(conn, 200, %{"refRates" => Enum.filter(rows, &(&1["effectiveDate"] >= s and (e == nil or &1["effectiveDate"] <= e)))})
    else
      bad(conn, "startDate required (ISO), endDate optional (ISO) and >= startDate")
    end
  end
end
