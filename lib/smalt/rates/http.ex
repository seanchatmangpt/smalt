defmodule Smalt.Rates.Http do
  @moduledoc "HTTP surface over Smalt.Rates twins (NY Fed, FRED, EDGAR, OpenCorporates, ABS pool)."
  use Plug.Router

  alias Smalt.Rates.{NyFed, Fred, Edgar, OpenCorporates, AbsPool}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  get "/markets/refrates/secured/sofr/last/1.json" do
    %{"refRates" => rows} = NyFed.ref_rates(:sofr)
    json(conn, 200, %{"refRates" => Enum.take(rows, 1)})
  end

  get "/fred/series/observations" do
    conn = fetch_query_params(conn)

    case Fred.observations(conn.query_params["series_id"] || "") do
      {:ok, body} -> json(conn, 200, body)
      {:error, body} -> json(conn, 400, body)
    end
  end

  get "/submissions/:file" do
    with {:ok, cik} <- cik_from(file, ~r/\ACIK(\d{10})\.json\z/),
         {:ok, body} <- Edgar.submissions(cik) do
      json(conn, 200, body)
    else
      _ -> json(conn, 404, %{"error" => "not_found"})
    end
  end

  get "/api/facts/:file" do
    with {:ok, cik} <- cik_from(file, ~r/\ACIK(\d{1,10})\.json\z/),
         {:ok, body} <- Edgar.company_facts(cik) do
      json(conn, 200, body)
    else
      _ -> json(conn, 404, %{"error" => "not_found"})
    end
  end

  get "/opencorporates/companies/:jur/:num/tree" do
    case OpenCorporates.tree(String.upcase(jur) <> "-" <> num) do
      {:ok, t} -> json(conn, 200, %{"results" => %{"tree" => t}})
      {:error, _} -> json(conn, 404, %{"error" => "not_found"})
    end
  end

  post "/abs/pool" do
    p = conn.body_params

    with id when is_binary(id) <- p["pool_id"],
         c when is_integer(c) and c > 0 <- p["principal_cents"],
         n when is_integer(n) and n > 0 <- p["n"] do
      json(conn, 200, AbsPool.pool(id, c, n))
    else
      _ -> json(conn, 422, %{"error" => "pool_id, principal_cents>0, n>0 required"})
    end
  end

  post "/abs/price" do
    p = conn.body_params

    with %{"principal_cents" => c} = pool when is_integer(c) <- p["pool"],
         {:ok, tranches} <- tranches(p["tranches"]),
         true <- Enum.sum(for {_, s, _} <- tranches, do: s) == 10_000 do
      rows =
        case p["sofr_bps"] do
          b when is_integer(b) -> AbsPool.price(pool, tranches, b)
          _ -> AbsPool.price(pool, tranches)
        end

      json(conn, 200, %{"tranches" => rows})
    else
      _ -> json(conn, 422, %{"error" => "pool and tranches (shares summing to 10000) required"})
    end
  end

  match _ do
    json(conn, 404, %{"error" => "not_found"})
  end

  defp tranches(list) when is_list(list) and list != [] do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"name" => n, "share_bps" => s, "spread_bps" => sp}, {:ok, acc}
      when is_integer(s) and is_integer(sp) ->
        {:cont, {:ok, acc ++ [{n, s, sp}]}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp tranches(_), do: :error

  defp cik_from(file, re) do
    case Regex.run(re, file) do
      [_, d] -> {:ok, String.to_integer(d)}
      _ -> :error
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
