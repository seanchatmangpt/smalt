defmodule Smalt.H08.TreasuryRouter do
  @moduledoc """
  H08 treasury routes, forwarded from `Smalt.Treasury.Router` (catch-all): pain.001 intake,
  camt.053/054 statements, Lithic ASA with funds logic, Plaid transactions, NACHA build/validate,
  plus account/card admin used to seed state.
  """
  use Plug.Router
  alias Smalt.H08.{Asa, Ledger, Nacha, Pain001, Statements, Vocab}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  defp json(conn, s, body), do: conn |> put_resp_content_type("application/json") |> send_resp(s, Jason.encode!(body))
  defp xml(conn, s, body), do: conn |> put_resp_content_type("application/xml") |> send_resp(s, body)
  defp err(conn, s, type, msg), do: json(conn, s, %{"type" => type, "message" => msg})

  defp plaid_err(conn, {type, code}, msg) do
    json(conn, 400, %{"error_type" => type, "error_code" => code, "error_message" => msg, "display_message" => nil,
                      "request_id" => "req_" <> (Base.encode32(:crypto.hash(:sha256, msg), case: :lower, padding: false) |> String.slice(0, 10))})
  end

  defp cents(v), do: v / 100

  post "/h08/accounts" do
    b = conn.body_params

    with id when is_binary(id) and id != "" <- b["account_id"],
         a when is_binary(a) <- b["account"],
         r when is_binary(r) <- b["routing"],
         o when is_integer(o) and o >= 0 <- b["opening_cents"] do
      case Ledger.open(id, %{account: a, routing: r, opening_cents: o}) do
        {:ok, acct} -> json(conn, 201, Map.new(acct, fn {k, v} -> {Atom.to_string(k), v} end))
        {:error, :exists} -> err(conn, 409, "conflict", "account exists")
      end
    else
      _ -> err(conn, 422, "invalid_request", "account_id, account, routing, opening_cents>=0 required")
    end
  end

  post "/h08/cards" do
    b = conn.body_params

    with t when is_binary(t) <- b["card_token"],
         m when is_list(m) <- b["mccs"],
         c when is_integer(c) and c > 0 <- b["max_amount_cents"],
         co when is_list(co) <- b["countries"],
         s when s in ["OPEN", "PAUSED", "CLOSED"] <- b["state"] || "OPEN" do
      Ledger.put_card(t, %{mccs: m, max_amount_cents: c, countries: co, account_id: b["account_id"], state: s})
      json(conn, 201, %{"card_token" => t, "state" => s})
    else
      _ -> err(conn, 422, "invalid_request", "card_token, mccs, max_amount_cents, countries, state in #{inspect(Vocab.card_states())} required")
    end
  end

  post "/h08/cards/:token/state" do
    s = conn.body_params["state"]

    case {Ledger.card(token), s in Vocab.card_states()} do
      {nil, _} -> err(conn, 404, "not_found", "card not found")
      {_, false} -> err(conn, 422, "invalid_request", "state must be one of #{inspect(Vocab.card_states())}")
      {rule, true} ->
        Ledger.put_card(token, Map.put(rule, :state, s))
        json(conn, 200, %{"card_token" => token, "state" => s})
    end
  end

  post "/lithic/asa" do
    case Asa.authorize(conn.body_params) do
      {:ok, d} -> json(conn, 200, Asa.response(d) |> Map.merge(Map.take(d, ["reasons", "available_cents"])))
      {:error, field} -> err(conn, 422, "invalid_request", "#{field} missing or invalid")
    end
  end

  post "/lithic/asa/clearing" do
    b = conn.body_params
    amt = b["amount"]

    cond do
      not is_binary(b["token"]) or not is_binary(b["booked"]) -> err(conn, 422, "invalid_request", "token and booked required")
      amt != nil and not (is_integer(amt) and amt > 0) -> err(conn, 422, "invalid_request", "amount must be positive integer cents")
      true ->
        case Asa.clear(b["token"], amt, b["booked"]) do
          {:ok, e} -> json(conn, 200, %{"token" => b["token"], "state" => "CLEARED", "amount" => e.amount_cents})
          {:error, :not_found} -> err(conn, 404, "not_found", "authorization not found")
          {:error, r} -> err(conn, 409, "conflict", to_string(r))
        end
    end
  end

  post "/lithic/asa/void" do
    case Asa.void(to_string(conn.body_params["token"])) do
      {:ok, _} -> json(conn, 200, %{"token" => conn.body_params["token"], "state" => "VOIDED"})
      {:error, :not_found} -> err(conn, 404, "not_found", "authorization not found")
      {:error, r} -> err(conn, 409, "conflict", to_string(r))
    end
  end

  post "/plaid/transactions/get" do
    b = conn.body_params
    tok = b["access_token"]
    {sd, ed} = {b["start_date"], b["end_date"]}
    opts = if is_map(b["options"]), do: b["options"], else: %{}
    count = opts["count"] || 100
    offset = opts["offset"] || 0
    date? = fn d -> is_binary(d) and match?({:ok, _}, Date.from_iso8601(d)) end

    cond do
      not is_binary(tok) or Ledger.account(tok) == nil -> plaid_err(conn, Vocab.plaid_invalid_token(), "the provided access token is invalid")
      sd == nil or ed == nil -> plaid_err(conn, Vocab.plaid_missing_field(), "start_date and end_date are required")
      not date?.(sd) or not date?.(ed) or sd > ed -> plaid_err(conn, Vocab.plaid_invalid_field(), "start_date and end_date must be ISO dates with start <= end")
      not (is_integer(count) and count in 1..500) or not (is_integer(offset) and offset >= 0) ->
        plaid_err(conn, Vocab.plaid_invalid_field(), "options.count 1..500 and options.offset >= 0 required")
      true ->
        a = Ledger.account(tok)

        posted =
          for e <- Ledger.entries(tok), e.booked >= sd, e.booked <= ed do
            %{"transaction_id" => "txn_#{tok}_#{e.seq}", "account_id" => a.account_id,
              "amount" => cents(if(e.direction == :debit, do: e.amount_cents, else: -e.amount_cents)),
              "iso_currency_code" => Vocab.currency(), "date" => e.booked, "name" => e.name, "pending" => false}
          end

        pending =
          for h <- Ledger.open_holds(tok), d = String.slice(h.created, 0, 10), d >= sd, d <= ed do
            %{"transaction_id" => "pend_#{h.token}", "account_id" => a.account_id, "amount" => cents(h.amount_cents),
              "iso_currency_code" => Vocab.currency(), "date" => d, "name" => h.name, "pending" => true}
          end

        all = Enum.sort_by(posted ++ pending, & &1["date"], :desc)

        json(conn, 200, %{"accounts" => [%{"account_id" => a.account_id,
                          "balances" => %{"available" => cents(a.available_cents), "current" => cents(a.current_cents),
                                          "iso_currency_code" => Vocab.currency()}}],
                          "transactions" => all |> Enum.drop(offset) |> Enum.take(count),
                          "total_transactions" => length(all), "request_id" => "req_txn"})
    end
  end

  post "/h08/iso20022/pain001/build" do
    b = conn.body_params

    with m when is_binary(m) <- b["msg_id"], c when is_binary(c) <- b["created_at"], x when is_binary(x) <- b["exec_date"],
         i when is_binary(i) <- b["initiator"], %{"name" => dn, "account" => da, "routing" => dr} <- b["debtor"],
         [_ | _] = ps <- b["payments"],
         {:ok, pays} <- pays(ps) do
      p = %{msg_id: m, created_at: c, exec_date: x, initiator: i, debtor: %{name: dn, account: da, routing: dr}, payments: pays}
      xml(conn, 200, Pain001.build(p))
    else
      _ -> err(conn, 422, "invalid_request", "msg_id, created_at, exec_date, initiator, debtor, payments[] with positive integer cents required")
    end
  end

  post "/h08/iso20022/pain001" do
    {:ok, body, conn} = read_body(conn)

    case Pain001.parse(body) do
      {:ok, p} -> json(conn, 200, Pain001.execute(p))
      {:error, {:missing, t}} -> err(conn, 422, "invalid_request", "pain.001 element missing: #{t}")
    end
  end

  get "/h08/iso20022/camt053/:id" do
    conn = fetch_query_params(conn)

    case Statements.camt053(id, conn.query_params["created_at"]) do
      {:ok, x} -> xml(conn, 200, x)
      {:error, :not_found} -> err(conn, 404, "not_found", "account not found")
    end
  end

  get "/h08/iso20022/camt054/:id" do
    conn = fetch_query_params(conn)

    case Integer.parse(conn.query_params["since_seq"] || "0") do
      {s, ""} when s >= 0 ->
        case Statements.camt054(id, s, conn.query_params["created_at"]) do
          {:ok, x} -> xml(conn, 200, x)
          {:error, :not_found} -> err(conn, 404, "not_found", "account not found")
        end

      _ -> err(conn, 422, "invalid_request", "since_seq must be a non-negative integer")
    end
  end

  post "/h08/nacha/file" do
    case Nacha.build(conn.body_params) do
      {:ok, text} -> conn |> put_resp_content_type("text/plain") |> send_resp(200, text)
      {:error, issues} -> json(conn, 422, %{"type" => "invalid_request", "issues" => issues})
    end
  end

  post "/h08/nacha/validate" do
    {:ok, body, conn} = read_body(conn)

    case Nacha.validate(body) do
      {:ok, s} -> json(conn, 200, Map.put(s, "valid", true))
      {:error, issues} -> json(conn, 200, %{"valid" => false, "issues" => issues})
    end
  end

  match _ do
    err(conn, 404, "not_found", "no such route")
  end

  defp pays(ps) do
    Enum.reduce_while(ps, {:ok, []}, fn
      %{"end_to_end_id" => e, "amount_cents" => a, "creditor" => %{"name" => n, "account" => ac, "routing" => r}}, {:ok, acc}
      when is_binary(e) and is_integer(a) and a > 0 ->
        {:cont, {:ok, acc ++ [%{end_to_end_id: e, amount_cents: a, creditor: %{name: n, account: ac, routing: r}}]}}

      _, _ ->
        {:halt, :error}
    end)
  end
end
