defmodule Smalt.AWS.DynamoDB.Router do
  @moduledoc """
  Wire face for DynamoDB (JSON 1.0), KMS (JSON 1.1, `TrentService.*`) and STS (Query/XML)
  (AS2). Plug; opts: `creds:` (%{akid => secret} or fun; STS-issued session keys are always
  also accepted), `verify:` (default true). Claims only conns whose SigV4 scope service is
  `dynamodb`, `kms` or `sts`; everything else passes through.

  MOUNT (coordinator, egress_router.ex):
  `plug(Smalt.AWS.DynamoDB.Router, creds: %{"AKIA..." => "secret"})`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.AWS.{DynamoDB, KMS, SigV4, STS}

  def init(o), do: o

  def call(conn, opts) do
    with ["AWS4-HMAC-SHA256" <> _ = a] <- get_req_header(conn, "authorization"),
         {:ok, %{service: svc}} when svc in ["dynamodb", "kms", "sts"] <- SigV4.parse_auth(a) do
      conn |> serve(svc, opts) |> halt()
    else
      _ -> conn
    end
  end

  defp creds(opts) do
    static = Keyword.get(opts, :creds, %{})

    fn akid ->
      base =
        case static do
          m when is_map(m) -> Map.fetch(m, akid)
          f when is_function(f, 1) -> f.(akid)
        end

      case base do
        {:ok, _} = ok -> ok
        _ -> STS.secret_for(akid)
      end
    end
  end

  defp serve(conn, svc, opts) do
    {:ok, body, conn} = read_body(conn, length: 16_000_000)

    verdict =
      if Keyword.get(opts, :verify, true),
        do: SigV4.verify(conn, body, creds(opts)),
        else: {:ok, nil}

    case verdict do
      {:ok, akid} -> route(conn, svc, body, akid, opts)
      {:error, :mismatch} -> deny(conn, svc, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.")
      {:error, :unknown_key} -> deny(conn, svc, "UnrecognizedClientException", "The security token included in the request is invalid.")
      {:error, _} -> deny(conn, svc, "MissingAuthenticationToken", "Request is missing Authentication Token")
    end
  end

  defp route(conn, "dynamodb", body, _akid, _opts) do
    with ["DynamoDB_20120810." <> op] <- get_req_header(conn, "x-amz-target"),
         {:ok, p} when is_map(p) <- Jason.decode(body) do
      {st, out} = DynamoDB.dispatch(op, p)
      json(conn, st, out, "application/x-amz-json-1.0")
    else
      _ -> json(conn, 400, %{"__type" => "com.amazon.coral.service#UnknownOperationException", "message" => ""}, "application/x-amz-json-1.0")
    end
  end

  defp route(conn, "kms", body, _akid, _opts) do
    with ["TrentService." <> op] <- get_req_header(conn, "x-amz-target"),
         {:ok, p} when is_map(p) <- Jason.decode(body) do
      {st, out} = KMS.dispatch(op, p)
      json(conn, st, out, "application/x-amz-json-1.1")
    else
      _ -> json(conn, 400, %{"__type" => "UnknownOperationException", "message" => ""}, "application/x-amz-json-1.1")
    end
  end

  defp route(conn, "sts", body, akid, opts) do
    params = URI.decode_query(body)
    id = Keyword.get(opts, :identities, %{})
    {st, xml} = STS.dispatch(params, akid, id)
    conn |> put_resp_content_type("text/xml") |> send_resp(st, xml)
  end

  defp json(conn, st, out, ct) do
    conn
    |> put_resp_header("x-amzn-requestid", Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    |> put_resp_content_type(ct)
    |> send_resp(st, Jason.encode!(out))
  end

  defp deny(conn, "sts", code, msg) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(403, STS.error_xml(code, msg))
  end

  defp deny(conn, "kms", code, msg), do: json(conn, 400, %{"__type" => code, "message" => msg}, "application/x-amz-json-1.1")
  defp deny(conn, _, code, msg), do: json(conn, 400, %{"__type" => code, "message" => msg}, "application/x-amz-json-1.0")
end
