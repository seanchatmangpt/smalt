defmodule Smalt.WebPubSub.Router do
  @moduledoc """
  REST + WS face for the Web PubSub emulator (AZ-5).

  Real-shape routes (cite https://learn.microsoft.com/rest/api/webpubsub/
  and the client protocol https://learn.microsoft.com/azure/azure-web-pubsub/
  websocket-client-protocol, subprotocol `json.webpubsub.azure.v1`):

    * `POST /webpubsub/hubs/:hub/generateToken?userId=&role=` -- mint a
      client access JWT (roles via repeatable `role` query param; default
      both all-groups wildcards).
    * `POST /webpubsub/hubs/:hub/negotiate` -- {"url", "accessToken"}
      (real negotiate response shape).
    * `GET  /webpubsub/hubs/:hub?access_token=<JWT>` -- the client WS
      upgrade (subprotocol `json.webpubsub.azure.v1`, KD-166).
    * `POST /webpubsub/hubs/:hub/groups/:group/:send` -- server push
      (real: 202 Accepted; body octet-stream => raw binary broadcast).

  KD-169 (v26.10.22): the server API faces are credential-gated — callers
  present the connection-string access key as `Authorization: Bearer <jwt>`
  (HS256 signed with the access key, `aud = https://<host>` — the form the
  real server SDKs send) or `Authorization: SharedAccessKey <key>` (raw-key
  dev form). Missing/wrong credential => typed 401 naming the face. The
  client WS upgrade face is unchanged (client JWT via `access_token=`).

  `# KD-COVERS: KD-166`
  `# KD-COVERS: KD-169`
  """

  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/webpubsub/hubs/:hub" do
    case token_from_conn(conn) do
      {:ok, token} ->
        case Smalt.WebPubSub.Token.verify(hub, token) do
          {:ok, user_id, roles} ->
            conn_id = conn_id()
            # Real service order: the connect event reaches the upstream
            # handler BEFORE the client connection is accepted.
            :ok = Smalt.WebPubSub.Events.connect(hub, conn_id, user_id)

            # KD-166: echo the client's requested WebSocket subprotocol in
            # the 101 (real Azure Web PubSub echoes the requested protocol;
            # bandit 1.13.1 does no subprotocol handling). Only echo when the
            # client offered one; the first/primary requested protocol wins.
            conn = echo_subprotocol(conn)

            Plug.Conn.upgrade_adapter(conn, :websocket, {
              Smalt.WebPubSub.Socket,
              %{hub: hub, user_id: user_id, roles: roles, conn_id: conn_id},
              []
            })

          :error ->
            unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
    end
  end

  post "/webpubsub/hubs/:hub/generateToken" do
    with :ok <- require_server_credential(conn, "generateToken") do
      conn = fetch_query_params(conn)
      user_id = conn.query_params["userId"] || default_user()
      roles = roles_from_conn(conn)
      token = Smalt.WebPubSub.Token.mint(hub, user_id, roles)
      json(conn, 200, %{"token" => token})
    end
  end

  post "/webpubsub/hubs/:hub/negotiate" do
    with :ok <- require_server_credential(conn, "negotiate") do
      conn = fetch_query_params(conn)
      user_id = conn.query_params["userId"] || default_user()
      roles = roles_from_conn(conn)
      token = mint(hub, user_id, roles)
      json(conn, 200, %{"url" => client_url(conn, hub, token), "accessToken" => token})
    end
  end

  post "/webpubsub/hubs/:hub/groups/:group/:action" do
    with :ok <- require_server_credential(conn, "groups:send") do
      case action do
        a when a in ["send", ":send"] ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          {:ok, n} = Smalt.WebPubSub.publish(hub, group, body)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, Jason.encode!(%{"delivered" => n}))

        _ ->
          send_resp(conn, 404, ~s({"error":"unknown action"}))
      end
    end
  end

  match _ do
    send_resp(conn, 404, ~s({"error":"not found: webpubsub face"}))
  end

  # -- Helpers ------------------------------------------------------------------

  # KD-169: server API faces require the connection-string access key. Two
  # accepted forms on the Authorization header:
  #
  #   * `Bearer <jwt>`  — HS256 signed with the access key, `aud` bound to
  #     `https://<host header>` and a live `exp` (the form real Azure server
  #     SDKs mint per request).
  #   * `SharedAccessKey <key>` — raw access key, constant-time compare.
  #
  # Anything else (absent, wrong key, wrong aud, expired) is a typed 401
  # naming the face. The client WS upgrade face above is UNCHANGED — client
  # connections ride the minted client JWTs (`access_token=`), not this gate.
  @server_faces ["generateToken", "negotiate", "groups:send"]

  defp require_server_credential(conn, face) when face in @server_faces do
    case server_credential_ok?(conn) do
      :ok ->
        :ok

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => reason, "face" => face}))
        |> halt()
    end
  end

  defp server_credential_ok?(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [value | _] -> check_authorization(value, conn)
      [] -> {:error, "missing server credential (Authorization header required)"}
    end
  end

  defp check_authorization("Bearer " <> jwt, conn) do
    signer = Joken.Signer.create("HS256", access_key())

    config = %{
      "aud" => %Joken.Claim{
        validate: fn val, _c, _ctx -> val == "https://" <> host_port(conn) end
      },
      "exp" => %Joken.Claim{
        validate: fn val, _c, _ctx -> is_integer(val) and val > System.system_time(:second) end
      }
    }

    case Joken.verify_and_validate(config, jwt, signer) do
      {:ok, _claims} -> :ok
      _ -> {:error, "invalid server credential (bad signature, audience, or expiry)"}
    end
  end

  defp check_authorization("SharedAccessKey " <> key, _conn) do
    if Plug.Crypto.secure_compare(key, access_key()) do
      :ok
    else
      {:error, "invalid server credential (access key mismatch)"}
    end
  end

  defp check_authorization(_other, _conn) do
    {:error, "unsupported Authorization scheme (Bearer <jwt> or SharedAccessKey <key>)"}
  end

  # Dev access key: same source Smalt.WebPubSub.Token signs client JWTs with
  # (the connection-string access-key analog). SMALT_WPS_ACCESS_KEY (dev-key
  # convention, cf. SMALT_SB_SHARED_KEY in scripts/dev_env.sh) overrides.
  defp access_key do
    System.get_env("SMALT_WPS_ACCESS_KEY") ||
      Application.get_env(:smalt, :web_pubsub_access_key, "smalt-wps-dev-access-key")
  end

  # KD-166: bandit 1.13.1 performs no Sec-WebSocket-Protocol negotiation, so
  # the 101 upgrade response omitted the subprotocol echo the real service
  # sends. Echo the client's first requested protocol when one was offered;
  # emit no header when the client requested none (RFC 6455 §4.1: the server
  # must not return a protocol the client did not request).
  defp echo_subprotocol(conn) do
    case Plug.Conn.get_req_header(conn, "sec-websocket-protocol") do
      [requested | _] ->
        first = requested |> String.split(",") |> List.first() |> String.trim()
        put_resp_header(conn, "sec-websocket-protocol", first)

      _ ->
        conn
    end
  end

  defp token_from_conn(conn) do
    conn = fetch_query_params(conn)
    case conn.query_params["access_token"] do
      nil -> :error
      t when is_binary(t) -> {:ok, t}
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"invalid or missing access_token"}))
  end

  defp roles_from_conn(conn) do
    case Plug.Conn.Query.decode(conn.query_string) do
      %{"role" => roles} when is_list(roles) -> roles
      %{"role" => role} when is_binary(role) -> [role]
      _ -> ["webpubsub.joinLeaveGroup", "webpubsub.sendToGroup"]
    end
  end

  defp mint(hub, user_id, roles), do: Smalt.WebPubSub.Token.mint(hub, user_id, roles)

  defp client_url(conn, hub, token) do
    "ws://#{host_port(conn)}/webpubsub/hubs/#{hub}?access_token=#{token}"
  end

  defp host_port(conn) do
    case Plug.Conn.get_req_header(conn, "host") do
      [h | _] -> h
      [] -> "127.0.0.1"
    end
  end

  defp conn_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp default_user, do: "user-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end
end
