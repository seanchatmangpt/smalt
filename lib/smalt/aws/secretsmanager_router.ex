defmodule Smalt.AWS.SecretsManager.Router do
  @moduledoc """
  Secrets Manager JSON-1.1 wire face (AS3), `X-Amz-Target: secretsmanager.*`.
  Plug; opts: `server:`, `creds:`, `verify:`. Claims SigV4 scope service
  `secretsmanager` only. MOUNT (coordinator): `plug(Smalt.AWS.SecretsManager.Router,
  server: Smalt.AWS.SecretsManager.Default, creds: ...)`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.AWS.{SecretsManager, SigV4}

  def init(o), do: o

  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["AWS4-HMAC-SHA256" <> _ = a] ->
        case SigV4.parse_auth(a) do
          {:ok, %{service: "secretsmanager", region: r}} -> conn |> serve(opts, r) |> halt()
          _ -> conn
        end

      _ -> conn
    end
  end

  defp serve(conn, opts, region) do
    {:ok, body, conn} = read_body(conn, length: 1_000_000)
    verified = if Keyword.get(opts, :verify, true), do: SigV4.verify(conn, body, Keyword.fetch!(opts, :creds)), else: {:ok, nil}

    case verified do
      {:ok, _} -> dispatch(conn, body, Keyword.fetch!(opts, :server), region)
      {:error, :mismatch} -> json(conn, 400, "InvalidSignatureException", "The request signature we calculated does not match the signature you provided.")
      {:error, :unknown_key} -> json(conn, 400, "UnrecognizedClientException", "The security token included in the request is invalid.")
      {:error, _} -> json(conn, 400, "AccessDeniedException", "Access Denied")
    end
  end

  defp dispatch(conn, body, s, region) do
    with ["secretsmanager." <> op] <- get_req_header(conn, "x-amz-target"),
         {:ok, p} when is_map(p) <- Jason.decode(if(body == "", do: "{}", else: body)) do
      res =
        case op do
          "CreateSecret" -> SecretsManager.call(s, :create, [region, p])
          "PutSecretValue" -> SecretsManager.call(s, :put_value, [p])
          "GetSecretValue" -> SecretsManager.call(s, :get_value, [p])
          "DescribeSecret" -> SecretsManager.call(s, :describe, [p])
          "DeleteSecret" -> SecretsManager.call(s, :delete, [p])
          "RestoreSecret" -> SecretsManager.call(s, :restore, [p])
          "ListSecrets" -> SecretsManager.call(s, :list, [p])
          _ -> {:error, "InvalidRequestException", "Unknown operation #{op}"}
        end

      case res do
        {:ok, m} -> conn |> put_resp_content_type("application/x-amz-json-1.1") |> send_resp(200, Jason.encode!(m))
        {:error, c, m} -> json(conn, 400, c, m)
      end
    else
      _ -> json(conn, 400, "InvalidRequestException", "Malformed request")
    end
  end

  defp json(conn, status, code, msg) do
    conn |> put_resp_content_type("application/x-amz-json-1.1") |> send_resp(status, Jason.encode!(%{"__type" => code, "Message" => msg}))
  end
end
