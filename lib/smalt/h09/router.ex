defmodule Smalt.H09.Router do
  @moduledoc """
  H09 JSON surface: OFAC screening, FIRE/IRIS 1099 filing, state sales-tax return, ERP
  journal/GL/trial balance, AR/AP sync, SWAR instant-wire admission mask.
  Mount: `forward "/h09", to: Smalt.H09.Router`. Errors: `{"error": kind, "detail": ...}`.
  """
  use Plug.Router
  alias Smalt.H09.{Ofac, Fire, SalesTax, Journal, Arap, Vocab}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/ofac/screen" do
    b = conn.body_params
    th = b["threshold_bps"] || Vocab.screen_default_threshold_bps()

    with name when is_binary(name) and name != "" <- b["name"],
         true <- is_integer(th) and th in 0..10_000,
         {:ok, list} <- list(b["list"]) do
      json(conn, 200, Ofac.screen(name, list, th))
    else
      _ -> fail(conn, 400, {Vocab.err(:invalid), [:name, :threshold_bps, :list]})
    end
  end

  get "/ofac/list" do
    json(conn, 200, %{entries: Vocab.sdn_fixture()})
  end

  post "/fire/1099" do
    case Fire.build_file(conn.body_params) do
      {:ok, r} -> json(conn, 200, r)
      {:error, e} -> fail(conn, 400, e)
    end
  end

  post "/iris/submissions" do
    case Fire.iris_submit(conn.body_params) do
      {:ok, r} -> json(conn, 201, r)
      {:error, {k, _} = e} when k == :duplicate_entry -> fail(conn, 409, e)
      {:error, e} -> fail(conn, 400, e)
    end
  end

  get "/iris/submissions/:id" do
    case Fire.iris_get(id) do
      {:ok, r} -> json(conn, 200, r)
      {:error, e} -> fail(conn, 404, e)
    end
  end

  post "/sales-tax/return" do
    case SalesTax.compute(conn.body_params) do
      {:ok, r} -> json(conn, 200, r)
      {:error, e} -> fail(conn, 422, e)
    end
  end

  get "/erp/gl/accounts" do
    json(conn, 200, %{accounts: Journal.accounts()})
  end

  post "/erp/journal/validate" do
    case Journal.validate(conn.body_params) do
      {:ok, r} -> json(conn, 200, Map.put(r, :valid, true))
      {:error, e} -> fail(conn, 422, e)
    end
  end

  post "/erp/journal" do
    case Journal.post(conn.body_params) do
      {:ok, r} -> json(conn, 201, r)
      {:error, {:duplicate_entry, _} = e} -> fail(conn, 409, e)
      {:error, {:invalid_request, _} = e} -> fail(conn, 400, e)
      {:error, e} -> fail(conn, 422, e)
    end
  end

  get "/erp/trial-balance" do
    conn = fetch_query_params(conn)
    json(conn, 200, Journal.trial_balance(conn.query_params["entity"]))
  end

  post "/erp/arap/sync" do
    case Arap.sync(conn.body_params) do
      {:ok, r} -> json(conn, 200, r)
      {:error, e} -> fail(conn, 400, e)
    end
  end

  get "/erp/arap/:entity/:kind" do
    conn = fetch_query_params(conn)

    case Arap.get(entity, kind, conn.query_params["asOf"] || Date.to_iso8601(Date.utc_today())) do
      {:ok, r} -> json(conn, 200, r)
      {:error, e} -> fail(conn, 400, e)
    end
  end

  get "/swar/gates" do
    json(conn, 200, %{gates: Enum.with_index(Smalt.Gatemask.gates()) |> Enum.map(fn {g, i} -> %{name: g, bit: i} end), required_mask: 0xFFFF})
  end

  post "/swar/admit" do
    case mask(conn.body_params) do
      {:ok, m} ->
        import Bitwise
        missing = for g <- Smalt.Gatemask.gates(), (m &&& Smalt.Gatemask.bit(g)) == 0, do: g

        case Smalt.Gatemask.admit_instant_wire(m) do
          :admitted -> json(conn, 200, %{admitted: true, mask: m, missing_gates: []})
          {:refused, code} -> json(conn, 200, %{admitted: false, mask: m, refusal_code: code, missing_gates: missing})
        end

      :error ->
        fail(conn, 400, {Vocab.err(:invalid), [:mask, :gates]})
    end
  end

  match _ do
    fail(conn, 404, {Vocab.err(:not_found), conn.request_path})
  end

  defp mask(%{"mask" => m}) when is_integer(m) and m >= 0 and m <= 0xFFFFFFFFFFFFFFFF, do: {:ok, m}

  defp mask(%{"gates" => gs}) when is_list(gs) do
    known = MapSet.new(Smalt.Gatemask.gates())

    if Enum.all?(gs, &(is_binary(&1) and MapSet.member?(known, &1))),
      do: {:ok, Enum.reduce(gs, 0, &Smalt.Gatemask.set_gate(&2, &1))},
      else: :error
  end

  defp mask(_), do: :error

  defp list(nil), do: {:ok, Vocab.sdn_fixture()}

  defp list(l) when is_list(l) do
    if Enum.all?(l, &(is_map(&1) and is_binary(&1["id"]) and is_binary(&1["name"]) and is_binary(&1["program"]))),
      do: {:ok, Enum.map(l, &%{id: &1["id"], name: &1["name"], program: &1["program"], aliases: Enum.filter(&1["aliases"] || [], fn a -> is_binary(a) end)})},
      else: :error
  end

  defp list(_), do: :error

  defp fail(conn, status, {k, d}), do: json(conn, status, %{error: k, detail: d})
  defp fail(conn, status, k) when is_atom(k), do: json(conn, status, %{error: k, detail: nil})

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
