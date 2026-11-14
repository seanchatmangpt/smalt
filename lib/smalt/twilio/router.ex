defmodule Smalt.Twilio.Router do
  @moduledoc """
  Plug router mirroring arcus TW1: Twilio REST emulation + fnox route law.
  Options: `account_sid:`, `auth_token:` (documented example values by default),
  `base_url:` (public URL used for signature verification), `store:` (Agent pid).
  """
  use Plug.Router
  alias Smalt.Twilio.{Core, Signature}

  @example_sid "AC" <> String.duplicate("a", 32)
  @example_token String.duplicate("b", 32)

  def start_store,
    do: Agent.start_link(fn -> %{numbers: [], messages: [], calls: [], events: []} end)

  def events(store), do: store |> Agent.get(& &1.events) |> Enum.reverse()

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:dispatch)

  def call(conn, opts) do
    conn = Plug.Conn.put_private(conn, :twilio_opts, opts)
    super(conn, opts)
  end

  defp opt(conn, k, default), do: Keyword.get(conn.private.twilio_opts, k, default)
  defp store(conn), do: Keyword.fetch!(conn.private.twilio_opts, :store)

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  defp refuse(conn, status, code, why),
    do: json(conn, status, %{"code" => code, "message" => to_string(why), "refused" => to_string(why), "status" => status})

  defp record(conn, act, objs),
    do: Agent.update(store(conn), fn s -> %{s | events: [Core.ocel_event(act, objs) | s.events]} end)

  # Route law: refused at the edge before any state access.
  get "/:role/:oid/:surface" do
    case Core.check_route(role, oid, surface) do
      {:ok, r} ->
        json(conn, 200, %{"role" => r.role, "otype" => r.otype, "id" => r.id, "surface" => r.surface, "fibo" => r.fibo})

      {:refused, why} ->
        refuse(conn, 403, 20403, why)
    end
  end

  post "/2010-04-01/Accounts/:acct/:resource" do
    case authorize(conn, acct) do
      :ok -> handle_rest(conn, acct, resource)
      {:error, why} -> refuse(conn, 401, 20003, why)
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp authorize(conn, acct) do
    token = opt(conn, :auth_token, @example_token)
    expected = opt(conn, :account_sid, @example_sid)

    cond do
      not Core.valid_account_sid?(acct) ->
        {:error, :bad_account_sid}

      acct != expected ->
        {:error, :unknown_account}

      true ->
        case Plug.BasicAuth.parse_basic_auth(conn) do
          {^acct, ^token} -> :ok
          _ -> verify_signature(conn, token)
        end
    end
  end

  defp verify_signature(conn, token) do
    base = opt(conn, :base_url, "http://" <> conn.host)
    qs = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    url = base <> conn.request_path <> qs
    given = conn |> get_req_header("x-twilio-signature") |> List.first()
    if Signature.valid?(token, url, conn.body_params, given), do: :ok, else: {:error, :bad_credentials}
  end

  defp handle_rest(conn, acct, "IncomingPhoneNumbers.json") do
    r = Core.incoming_number(acct, conn.body_params)
    Agent.update(store(conn), fn s -> %{s | numbers: [r | s.numbers]} end)
    record(conn, "number_provisioned", [r["sid"]])
    json(conn, 201, r)
  end

  defp handle_rest(conn, acct, "Messages.json") do
    p = conn.body_params

    if is_nil(p["To"]) or is_nil(p["From"]) do
      refuse(conn, 400, 21604, :missing_to_or_from)
    else
      r = Core.message(acct, p)
      Agent.update(store(conn), fn s -> %{s | messages: [r | s.messages]} end)
      record(conn, "message_created", [r["sid"]])
      json(conn, 201, r)
    end
  end

  defp handle_rest(conn, acct, "Calls.json") do
    p = conn.body_params

    if is_nil(p["To"]) or is_nil(p["From"]) do
      refuse(conn, 400, 21201, :missing_to_or_from)
    else
      r = Core.call(acct, p)
      Agent.update(store(conn), fn s -> %{s | calls: [r | s.calls]} end)
      record(conn, "call_created", [r["sid"]])
      json(conn, 201, r)
    end
  end

  defp handle_rest(conn, _acct, _), do: send_resp(conn, 404, "not found")
end
