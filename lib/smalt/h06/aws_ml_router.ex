defmodule Smalt.H06.AwsMl.Router do
  @moduledoc """
  H06 wire face for the AWS ML plane. Plug; opts: `creds:` (%{akid => secret} or
  fun; STS-issued session keys also accepted), `verify:` (default true).
  Claims only SigV4 scopes `textract`, `transcribe`, `rekognition` (JSON 1.1,
  `X-Amz-Target`) and `bedrock` (restJson1, `POST /model/{modelId}/converse`).
  Everything else passes through un-halted.

  MOUNT (coordinator, lib/smalt/egress_router.ex `aws_plane/2`, after the
  SecretsManager `aws_next`):
  `|> aws_next(&Smalt.H06.AwsMl.Router.call(&1, creds: creds))`
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.AWS.{SigV4, STS}
  alias Smalt.H06.{AwsMl, Vocab}

  def init(o), do: o

  def call(conn, opts) do
    with ["AWS4-HMAC-SHA256" <> _ = a] <- get_req_header(conn, "authorization"),
         {:ok, %{service: svc}} <- SigV4.parse_auth(a),
         true <- svc in Vocab.services() do
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
      if Keyword.get(opts, :verify, true), do: SigV4.verify(conn, body, creds(opts)), else: {:ok, nil}

    case verdict do
      {:ok, _} -> route(conn, svc, body)
      {:error, :mismatch} -> err(conn, svc, 403, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.")
      {:error, :unknown_key} -> err(conn, svc, 400, "UnrecognizedClientException", "The security token included in the request is invalid.")
      {:error, _} -> err(conn, svc, 400, "MissingAuthenticationToken", "Request is missing Authentication Token")
    end
  end

  defp route(conn, "bedrock", body) do
    with "POST" <- conn.method,
         ["model", model, "converse"] <- Enum.map(conn.path_info, &URI.decode/1),
         {:ok, p} when is_map(p) <- Jason.decode(body) do
      reply(conn, "bedrock", AwsMl.converse(model, p))
    else
      {:error, _} -> err(conn, "bedrock", 400, "ValidationException", "Malformed JSON body")
      _ -> err(conn, "bedrock", 404, "UnknownOperationException", "Unknown route #{conn.method} #{conn.request_path}")
    end
  end

  defp route(conn, svc, body) do
    prefix = Vocab.target_prefix(svc)

    with [t] <- get_req_header(conn, "x-amz-target"),
         true <- String.starts_with?(t, prefix),
         {:ok, p} when is_map(p) <- Jason.decode(body) do
      reply(conn, svc, AwsMl.dispatch(svc, String.replace_prefix(t, prefix, ""), p))
    else
      {:error, _} -> err(conn, svc, 400, "SerializationException", "Start of structure or map found where not expected.")
      _ -> err(conn, svc, 400, "UnknownOperationException", "Missing or foreign X-Amz-Target")
    end
  end

  defp reply(conn, svc, {:ok, out}), do: json(conn, svc, 200, out)
  defp reply(conn, svc, {:error, st, type, msg}), do: err(conn, svc, st, type, msg)

  defp err(conn, "bedrock", st, type, msg) do
    conn |> put_resp_header("x-amzn-errortype", type) |> json("bedrock", st, %{"message" => msg})
  end

  defp err(conn, svc, st, type, msg), do: json(conn, svc, st, %{"__type" => type, "message" => msg})

  defp json(conn, svc, st, out) do
    ct = if svc == "bedrock", do: Vocab.json(), else: Vocab.json11()

    conn
    |> put_resp_header("x-amzn-requestid", Base.encode16(:crypto.hash(:sha256, Jason.encode!(out)) |> binary_part(0, 8), case: :lower))
    |> put_resp_content_type(ct)
    |> send_resp(st, Jason.encode!(out))
  end
end
