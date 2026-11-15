defmodule Smalt.Treasury.Router do
  @moduledoc """
  REST face for Plane 1: Column/Modern-Treasury-style objects, ASA webhook, Plaid auth/balance.
  State lives in ETS table `:smalt_treasury` (created lazily by `ensure/0`).
  """
  use Plug.Router
  alias Smalt.Treasury.{Asa, Iso20022, Rails}

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  @t :smalt_treasury

  def ensure do
    if :ets.whereis(@t) == :undefined do
      # Table is owned by the long-lived Store process, never by a request process.
      case GenServer.start(Smalt.Treasury.Store, @t, name: Smalt.Treasury.Store) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> :ok
      end
    end

    :ok
  end

  @doc false
  def dec(c) when is_integer(c) do
    sign = if c < 0, do: "-", else: ""
    a = abs(c)
    sign <> Integer.to_string(div(a, 100)) <> "." <> (a |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0"))
  end

  defp party(%{} = m) do
    with n when is_binary(n) and n != "" <- m["name"],
         a when is_binary(a) and a != "" <- m["account"],
         r when is_binary(r) and r != "" <- m["routing"] do
      {:ok, %{name: n, account: a, routing: r}}
    else
      _ -> :error
    end
  end

  defp party(_), do: :error

  defp str(v) when is_binary(v), do: v
  defp str(_), do: ""

  def put_card_rule(card_token, rule), do: (ensure(); :ets.insert(@t, {{:rule, card_token}, rule}))
  def put_account(id, a), do: (ensure(); :ets.insert(@t, {{:account, id}, a}))

  defp get(k), do: (ensure(); case :ets.lookup(@t, k) do [{_, v}] -> v; _ -> nil end)
  defp store(k, v), do: (ensure(); :ets.insert(@t, {k, v}); v)

  defp json(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp err(conn, s, type, msg), do: json(conn, s, %{"type" => type, "message" => msg})

  defp id(p), do: p <> "_" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)

  post "/transfers/ach" do
    b = conn.body_params

    with a when is_integer(a) and a > 0 <- b["amount"],
         acct when is_binary(acct) <- b["bank_account_id"],
         %{} = ba <- get({:account, acct}) do
      speed = if b["same_day"] == true, do: :same_day, else: :standard
      {:ok, rail} = Rails.select(%{amount_cents: a, speed: speed})
      t = %{"id" => id("ach"), "amount" => a, "currency_code" => "USD", "bank_account_id" => acct,
            "status" => "initiated", "rail" => to_string(rail), "same_day" => b["same_day"] == true}
      _ = ba
      json(conn, 201, store({:transfer, t["id"]}, t))
    else
      nil -> err(conn, 404, "not_found", "bank account not found")
      _ -> err(conn, 400, "invalid_request", "amount must be positive integer cents")
    end
  end

  post "/transfers/wire" do
    b = conn.body_params

    case b["amount"] do
      a when is_integer(a) and a > 0 ->
        t = %{"id" => id("wire"), "amount" => a, "status" => "initiated", "rail" => "fedwire"}
        json(conn, 201, store({:transfer, t["id"]}, t))

      _ ->
        err(conn, 400, "invalid_request", "amount must be positive integer cents")
    end
  end

  post "/payment_orders" do
    b = conn.body_params
    speed = case b["priority"] do "instant" -> :instant; "same_day" -> :same_day; "high_value" -> :high_value; _ -> :standard end

    case b["amount"] do
      a when is_integer(a) and a > 0 ->
        {:ok, rail} = Rails.select(%{amount_cents: a, speed: speed})
        po = %{"id" => id("po"), "amount" => a, "currency" => "USD", "direction" => b["direction"] || "credit",
               "type" => to_string(rail), "status" => "approved"}
        json(conn, 201, store({:po, po["id"]}, po))

      _ ->
        err(conn, 400, "invalid_request", "amount must be positive integer cents")
    end
  end

  get "/payment_orders/:pid" do
    case get({:po, pid}) do nil -> err(conn, 404, "not_found", "payment order not found"); po -> json(conn, 200, po) end
  end

  get "/transfers/:tid" do
    case get({:transfer, tid}) do nil -> err(conn, 404, "not_found", "transfer not found"); t -> json(conn, 200, t) end
  end

  post "/iso20022/pacs008" do
    b = conn.body_params

    with a when is_integer(a) and a > 0 <- b["amount"],
         {:ok, d} <- party(b["debtor"]),
         {:ok, c} <- party(b["creditor"]) do
      p = %{msg_id: str(b["msg_id"]), created_at: str(b["created_at"]), end_to_end_id: str(b["end_to_end_id"]),
            amount_cents: a, debtor: d, creditor: c}

      conn |> put_resp_content_type("application/xml") |> send_resp(200, Iso20022.pacs008(p))
    else
      _ -> err(conn, 422, "invalid_request", "amount must be positive integer cents; debtor and creditor need name, account, routing")
    end
  end

  post "/plaid/auth/get" do
    case get({:account, conn.body_params["access_token"]}) do
      nil -> err(conn, 400, "ITEM_ERROR", "INVALID_ACCESS_TOKEN")
      a ->
        json(conn, 200, %{"accounts" => [%{"account_id" => a.account_id, "balances" => %{"available" => dec(a.available_cents)}}],
                          "numbers" => %{"ach" => [%{"account_id" => a.account_id, "account" => a.account, "routing" => a.routing}]},
                          "request_id" => id("req")})
    end
  end

  post "/plaid/accounts/balance/get" do
    case get({:account, conn.body_params["access_token"]}) do
      nil -> err(conn, 400, "ITEM_ERROR", "INVALID_ACCESS_TOKEN")
      a ->
        json(conn, 200, %{"accounts" => [%{"account_id" => a.account_id,
                          "balances" => %{"available" => dec(a.available_cents), "current" => dec(a.current_cents),
                                          "iso_currency_code" => "USD"}}], "request_id" => id("req")})
    end
  end

  post "/webhooks/asa" do
    a = conn.body_params

    case get({:rule, a["card_token"]}) do
      nil -> json(conn, 200, %{"result" => "DECLINED", "token" => a["token"], "reasons" => ["NO_RULE"]})
      rule -> json(conn, 200, Asa.response(Asa.decide(a, rule)))
    end
  end

  forward("/", to: Smalt.H08.TreasuryRouter)

  match _ do
    err(conn, 404, "not_found", "no such route")
  end
end

defmodule Smalt.Treasury.Store do
  @moduledoc "Long-lived owner of the :smalt_treasury ETS table (survives request processes)."
  use GenServer

  @impl true
  def init(t) do
    if :ets.whereis(t) == :undefined, do: :ets.new(t, [:named_table, :public, :set])
    {:ok, t}
  end
end
