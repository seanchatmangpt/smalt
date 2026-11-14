defmodule Smalt.Webhooks.Plug do
  @moduledoc """
  Plug refusing webhooks with bad/missing/stale signatures as typed 400s.

  Requires the raw body: set `conn.assigns[:raw_body]` (via a body reader upstream) or
  this plug reads the body itself when unparsed.

  Options: `:scheme` (`:stripe` | `:svix`, default `:stripe`), `:secret` (binary or
  `{m, f, a}`/fun/0), `:tolerance`, `:now` (test hook).

  Refusal body: `{"error":"webhook_signature_invalid","reason":"<atom>"}`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.Webhooks.Signature

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {conn, body} = raw_body(conn)
    secret = resolve(Keyword.fetch!(opts, :secret))
    vopts = Keyword.take(opts, [:tolerance, :now])

    result =
      case Keyword.get(opts, :scheme, :stripe) do
        :stripe ->
          Signature.verify_stripe(body, header(conn, "stripe-signature"), secret, vopts)

        :svix ->
          headers =
            for k <- ~w(svix-id svix-timestamp svix-signature), into: %{} do
              {k, header(conn, k)}
            end

          Signature.verify_svix(body, headers, secret, vopts)
      end

    case result do
      :ok -> assign(conn, :raw_body, body)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      b when is_binary(b) ->
        {conn, b}

      _ ->
        case read_body(conn) do
          {:ok, b, conn} -> {conn, b}
          {:more, b, conn} -> {conn, b}
          {:error, _} -> {conn, ""}
        end
    end
  end

  defp header(conn, k), do: conn |> get_req_header(k) |> List.first()

  defp resolve(s) when is_binary(s), do: s
  defp resolve(f) when is_function(f, 0), do: f.()
  defp resolve({m, f, a}), do: apply(m, f, a)

  defp refuse(conn, reason) do
    body = ~s({"error":"webhook_signature_invalid","reason":"#{reason}"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
    |> halt()
  end
end
