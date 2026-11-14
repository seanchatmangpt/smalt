defmodule Smalt.GCP.Identity do
  @moduledoc """
  GCP identity plane: OAuth2 token endpoint (jwt-bearer + refresh-less
  client grants), tokeninfo, and the GCE metadata server. Stateless tokens:
  `ya29.<RS256 JWS>` signed by a per-VM RSA key, so tokeninfo verifies by
  signature, not by a table.
  """
  import Plug.Conn

  @token_uri "https://oauth2.googleapis.com/token"
  @ttl 3600
  @default_sa "default@smalt-local.iam.gserviceaccount.com"

  def token_uri, do: @token_uri

  def key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        :global.trans({{__MODULE__, :key}, self()}, fn ->
          case :persistent_term.get({__MODULE__, :key}, nil) do
            nil ->
              k = JOSE.JWK.generate_key({:rsa, 2048})
              :persistent_term.put({__MODULE__, :key}, k)
              k

            k ->
              k
          end
        end)

      k ->
        k
    end
  end

  @doc "Register a service account's public key PEM (for jwt-bearer verification)."
  def register_service_account(email, public_pem) when is_binary(email) do
    :persistent_term.put({__MODULE__, :sa, email}, JOSE.JWK.from_pem(public_pem))
    :ok
  end

  def mint(email, scope, ttl \\ @ttl) do
    now = System.os_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "sub" => email,
      "email" => email,
      "azp" => email,
      "aud" => email,
      "scope" => scope,
      "iat" => now,
      "exp" => now + ttl
    }

    {_, jws} = JOSE.JWT.sign(key(), %{"alg" => "RS256", "typ" => "JWT"}, claims) |> JOSE.JWS.compact()
    %{access_token: "ya29." <> jws, expires_in: ttl, token_type: "Bearer", scope: scope}
  end

  def mint_identity(email, audience) do
    now = System.os_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "sub" => email,
      "email" => email,
      "email_verified" => true,
      "aud" => audience,
      "iat" => now,
      "exp" => now + @ttl
    }

    {_, jws} = JOSE.JWT.sign(key(), %{"alg" => "RS256", "typ" => "JWT"}, claims) |> JOSE.JWS.compact()
    jws
  end

  @doc "Verify a `ya29.` access token. {:ok, claims} | {:error, reason}"
  def verify("ya29." <> jws) do
    with {true, %JOSE.JWT{fields: f}, _} <- safe_verify(key(), jws),
         true <- f["exp"] > System.os_time(:second) || {:error, :expired} do
      {:ok, f}
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_), do: {:error, :invalid_token}

  defp safe_verify(jwk, jws) do
    case JOSE.JWT.verify_strict(jwk, ["RS256"], jws) do
      {true, _, _} = ok -> ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  ## ---- OAuth2 token endpoint ----

  def token(conn) do
    {:ok, conn} = ensure_body(conn)
    p = conn.body_params

    case p["grant_type"] do
      "urn:ietf:params:oauth:grant-type:jwt-bearer" -> jwt_bearer(conn, p["assertion"])
      _ -> json(conn, 400, %{error: "unsupported_grant_type", error_description: "Invalid grant_type"})
    end
  end

  defp jwt_bearer(conn, assertion) when is_binary(assertion) do
    with {:ok, email} <- peek_iss(assertion),
         %JOSE.JWK{} = jwk <- :persistent_term.get({__MODULE__, :sa, email}, nil),
         {true, %JOSE.JWT{fields: f}, _} <- safe_verify(jwk, assertion),
         true <- f["aud"] == @token_uri,
         true <- is_integer(f["exp"]) and f["exp"] > System.os_time(:second),
         true <- is_binary(f["scope"]) and f["scope"] != "" do
      json(conn, 200, mint(email, f["scope"]))
    else
      _ -> json(conn, 400, %{error: "invalid_grant", error_description: "Invalid JWT Signature."})
    end
  end

  defp jwt_bearer(conn, _),
    do: json(conn, 400, %{error: "invalid_request", error_description: "Missing required parameter: assertion"})

  defp peek_iss(jws) do
    %JOSE.JWT{fields: %{"iss" => iss}} = JOSE.JWT.peek_payload(jws)
    {:ok, iss}
  rescue
    _ -> :error
  end

  def tokeninfo(conn) do
    {:ok, conn} = ensure_body(conn)
    t = conn.params["access_token"] || conn.body_params["access_token"]

    case verify(t || "") do
      {:ok, f} ->
        json(conn, 200, %{
          "azp" => f["azp"],
          "aud" => f["aud"],
          "scope" => f["scope"],
          "exp" => Integer.to_string(f["exp"]),
          "expires_in" => Integer.to_string(max(f["exp"] - System.os_time(:second), 0)),
          "email" => f["email"],
          "email_verified" => "true",
          "access_type" => "online"
        })

      _ ->
        json(conn, 400, %{error: "invalid_token", error_description: "Invalid Value"})
    end
  end

  ## ---- GCE metadata server ----

  def metadata(conn, segments) do
    cond do
      get_req_header(conn, "metadata-flavor") != ["Google"] ->
        conn |> put_resp_header("metadata-flavor", "Google") |> send_resp(403, "Missing Metadata-Flavor:Google header.\n")

      true ->
        conn = put_resp_header(conn, "metadata-flavor", "Google")
        email = Application.get_env(:smalt, :gcp_default_sa, @default_sa)

        case segments do
          ["computeMetadata", "v1"] ->
            text(conn, "instance/\nproject/\n")

          ["computeMetadata", "v1", "instance", "service-accounts", "default", "token"] ->
            t = mint(email, "https://www.googleapis.com/auth/cloud-platform")
            json(conn, 200, %{access_token: t.access_token, expires_in: t.expires_in, token_type: "Bearer"})

          ["computeMetadata", "v1", "instance", "service-accounts", "default", "email"] ->
            text(conn, email)

          ["computeMetadata", "v1", "instance", "service-accounts", "default", "identity"] ->
            case conn.params["audience"] do
              a when is_binary(a) and a != "" -> text(conn, mint_identity(email, a))
              _ -> send_resp(conn, 400, "non-empty audience parameter required\n")
            end

          ["computeMetadata", "v1", "project", "project-id"] ->
            text(conn, Application.get_env(:smalt, :gcp_project_id, "smalt-local"))

          _ ->
            send_resp(conn, 404, "not found\n")
        end
    end
  end

  defp text(conn, body),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(200, body)

  def json(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp ensure_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    opts = Plug.Parsers.init(parsers: [:urlencoded, :json], json_decoder: Jason, pass: ["*/*"])
    {:ok, Plug.Parsers.call(fetch_query_params(conn), opts)}
  end

  defp ensure_body(conn), do: {:ok, fetch_query_params(conn)}
end
