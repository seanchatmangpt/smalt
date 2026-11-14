defmodule Smalt.TaxSanctions.Http do
  @moduledoc """
  JSON HTTP surface over the pure Smalt.TaxSanctions modules. Integer cents only.

  Routes: POST /tin-match, /withholding, /1099/nec, /1099/k, /w8ben-e, /dac7, /screen;
  GET /vies/:country/:vat (registry from `config :smalt, :vies_registry`, a MapSet or list).
  Errors: `{"error": <type>, "detail": ...}` with 400 (invalid input) or 422 (domain refusal).
  """
  use Plug.Router

  alias Smalt.TaxSanctions.{TinMatch, BackupWithholding, Form1099, W8BenE, Vies, Screening}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  @nec_keys ~w(payer_tin payee_tin payee_name tax_year nonemployee_comp_cents federal_withheld_cents)a
  @k_keys ~w(filer_tin payee_tin payee_name tax_year monthly_gross_cents federal_withheld_cents)a
  @w8_keys ~w(entity_name country_of_incorporation chapter3_status permanent_address signature
              signed_on capacity treaty_country lob_qualified treaty_rate_pct)a
  @seller_keys ~w(name tin vat residence listings activities quarterly_consideration_cents fees_cents)a
  @entry_keys ~w(id name aliases program)a

  post "/tin-match" do
    with {:ok, name} <- str(conn, "name"),
         {:ok, tin} <- str(conn, "tin") do
      registry = registry(conn.body_params["registry"])
      seen = seen(conn.body_params["seen"])
      code = TinMatch.match(name, tin, registry, seen)
      ok(conn, %{code: code, meaning: TinMatch.code_meaning(code), matched: TinMatch.matched?(code)})
    else
      {:error, e} -> err(conn, 400, e)
    end
  end

  post "/withholding" do
    amt = conn.body_params["amount_cents"]
    code = conn.body_params["code"]

    if is_integer(amt) and amt >= 0 and is_integer(code) and code in 0..8 do
      ok(conn, BackupWithholding.divert(amt, code))
    else
      err(conn, 400, {:invalid, [:amount_cents, :code]})
    end
  end

  post "/1099/nec" do
    case Form1099.nec(pick(conn.body_params, @nec_keys)) do
      {:ok, r} -> ok(conn, r)
      {:error, e} -> err(conn, 422, e)
    end
  end

  post "/1099/k" do
    case Form1099.k(pick(conn.body_params, @k_keys)) do
      {:ok, r} -> ok(conn, r)
      {:error, e} -> err(conn, 422, e)
    end
  end

  post "/w8ben-e" do
    f = pick(conn.body_params, @w8_keys)

    case W8BenE.validate(f) do
      :ok ->
        exp =
          with s when is_binary(s) <- f[:signed_on], {:ok, d} <- Date.from_iso8601(s) do
            Date.to_iso8601(W8BenE.expires_on(d))
          else
            _ -> nil
          end

        ok(conn, %{valid: true, expires_on: exp})

      {:error, errs} ->
        err(conn, 422, errs)
    end
  end

  get "/vies/:country/:vat" do
    reg = :smalt |> Application.get_env(:vies_registry, []) |> MapSet.new()
    ok(conn, Vies.check(country <> vat, reg))
  end

  post "/dac7" do
    b = conn.body_params

    with pid when is_binary(pid) <- b["platform_id"],
         y when is_integer(y) <- b["year"],
         sellers when is_list(sellers) <- b["sellers"],
         true <- Enum.all?(sellers, &valid_seller?/1) do
      ok(conn, Vies.dac7_report(%{platform_id: pid, year: y, sellers: Enum.map(sellers, &pick(&1, @seller_keys))}))
    else
      _ -> err(conn, 400, {:invalid, [:platform_id, :year, :sellers]})
    end
  end

  post "/screen" do
    b = conn.body_params
    th = b["threshold"]

    with {:ok, name} <- str(conn, "name"),
         list when is_list(list) <- b["list"],
         true <- Enum.all?(list, &valid_entry?/1),
         true <- is_nil(th) or is_number(th) do
      entries = Enum.map(list, &pick(&1, @entry_keys))
      ok(conn, Screening.result(name, entries, th || 0.85))
    else
      {:error, e} -> err(conn, 400, e)
      _ -> err(conn, 400, {:invalid, [:name, :list, :threshold]})
    end
  end

  match _ do
    err(conn, 404, :not_found)
  end

  # ---- helpers ----

  defp valid_seller?(%{} = s) do
    q = s["quarterly_consideration_cents"]

    is_integer(s["activities"]) and is_list(q) and Enum.all?(q, &is_integer/1)
  end

  defp valid_seller?(_), do: false

  defp valid_entry?(%{"id" => _, "name" => n, "program" => _} = e) when is_binary(n),
    do: is_list(e["aliases"] || []) and Enum.all?(e["aliases"] || [], &is_binary/1)

  defp valid_entry?(_), do: false

  defp str(conn, key) do
    case conn.body_params[key] do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, {:invalid, [String.to_atom(key)]}}
    end
  end

  # whitelisted atomization (no atom minting from input)
  defp pick(%{} = m, keys) do
    for k <- keys, v = Map.get(m, Atom.to_string(k)), not is_nil(v), into: %{}, do: {k, v}
  end

  defp registry(%{} = r) do
    for {tin, %{"name" => n, "type" => t}} <- r, t in ["ssn", "ein"], is_binary(n), into: %{} do
      {tin, %{name: n, type: String.to_atom(t)}}
    end
  end

  defp registry(_), do: %{}

  defp seen(l) when is_list(l) do
    for [n, t] <- l, is_binary(n), is_binary(t), into: MapSet.new(), do: {n, t}
  end

  defp seen(_), do: MapSet.new()

  defp ok(conn, body), do: send_json(conn, 200, body)
  defp err(conn, status, e), do: send_json(conn, status, %{error: kind(e), detail: enc(e)})

  defp kind({k, _}) when is_atom(k), do: k
  defp kind(k) when is_atom(k), do: k
  defp kind([{k, _} | _]) when is_atom(k), do: k
  defp kind(_), do: :error

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(enc(body)))
  end

  defp enc(%{} = m) when not is_struct(m), do: Map.new(m, fn {k, v} -> {k, enc(v)} end)
  defp enc(%MapSet{} = s), do: s |> MapSet.to_list() |> enc()
  defp enc(l) when is_list(l), do: Enum.map(l, &enc/1)
  defp enc(t) when is_tuple(t), do: t |> Tuple.to_list() |> enc()
  defp enc(v), do: v
end
