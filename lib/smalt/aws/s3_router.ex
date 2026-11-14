defmodule Smalt.AWS.S3.Router do
  @moduledoc """
  S3 REST path-style wire face (AS1). Plug; opts: `server:` (S3.Server name),
  `creds:` (%{akid => secret} or fun), `verify:` (default true), `min_part:`.
  Claims only conns whose Authorization is AWS4-HMAC-SHA256 with scope service
  `s3`; others pass through. MOUNT (coordinator, egress_router.ex):
  `plug(Smalt.AWS.S3.Router, server: Smalt.AWS.S3.Default, creds: ...)`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.AWS.{S3, SigV4}
  alias Smalt.AWS.S3.Server

  def init(o), do: o

  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["AWS4-HMAC-SHA256" <> _ = a] ->
        case SigV4.parse_auth(a) do
          {:ok, %{service: "s3"}} -> conn |> serve(opts) |> halt()
          _ -> conn
        end

      _ -> conn
    end
  end

  defp serve(conn, opts) do
    {:ok, body, conn} = read_body(conn, length: 64_000_000)

    case if(Keyword.get(opts, :verify, true), do: SigV4.verify(conn, body, Keyword.fetch!(opts, :creds)), else: {:ok, nil}) do
      {:ok, _} -> route(conn, body, opts)
      {:error, :mismatch} -> error(conn, 403, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.")
      {:error, :unknown_key} -> error(conn, 403, "InvalidAccessKeyId", "The AWS Access Key Id you provided does not exist in our records.")
      {:error, _} -> error(conn, 403, "AccessDenied", "Access Denied")
    end
  end

  defp route(conn, body, opts) do
    s = Keyword.fetch!(opts, :server)
    q = conn.query_string |> URI.decode_query()
    segs = conn.request_path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

    case {conn.method, segs} do
      {"GET", []} -> xml(conn, 200, list_buckets_xml(Server.read(s, &S3.list_buckets/1)))
      {m, [b]} -> bucket(conn, m, b, q, s)
      {m, [b | rest]} -> object(conn, m, b, Enum.join(rest, "/"), q, body, s, opts)
      _ -> error(conn, 405, "MethodNotAllowed", "The specified method is not allowed against this resource.")
    end
  end

  defp bucket(conn, "PUT", b, _q, s), do: reply(conn, Server.update(s, &S3.create_bucket(&1, b)), fn _ -> send_resp(put_resp_header(conn, "location", "/" <> b), 200, "") end)
  defp bucket(conn, "HEAD", b, _q, s), do: reply(conn, Server.read(s, &S3.head_bucket(&1, b)), fn _ -> send_resp(conn, 200, "") end, true)
  defp bucket(conn, "DELETE", b, _q, s), do: reply(conn, Server.update(s, &S3.delete_bucket(&1, b)), fn _ -> send_resp(conn, 204, "") end)

  defp bucket(conn, "GET", b, q, s) do
    o = %{prefix: q["prefix"], delimiter: q["delimiter"], start_after: q["continuation-token"] || q["start-after"],
          max_keys: if(q["max-keys"], do: String.to_integer(q["max-keys"]))}
    reply(conn, Server.read(s, &S3.list_objects(&1, b, o)), fn r -> xml(conn, 200, list_xml(b, q, r)) end)
  end

  defp bucket(conn, _, _, _, _), do: error(conn, 405, "MethodNotAllowed", "The specified method is not allowed against this resource.")

  defp object(conn, "POST", b, k, %{"uploads" => _}, _body, s, _o) do
    ct = hdr(conn, "content-type")
    reply(conn, Server.update(s, &S3.create_multipart(&1, b, k, %{content_type: ct})), fn id ->
      xml(conn, 200, ~s(<InitiateMultipartUploadResult><Bucket>#{esc(b)}</Bucket><Key>#{esc(k)}</Key><UploadId>#{id}</UploadId></InitiateMultipartUploadResult>))
    end)
  end

  defp object(conn, "POST", b, k, %{"uploadId" => id}, body, s, o) do
    parts = Regex.scan(~r/<Part>\s*<PartNumber>(\d+)<\/PartNumber>\s*<ETag>(.*?)<\/ETag>\s*<\/Part>/s, body)
            |> Enum.map(fn [_, n, e] -> {String.to_integer(n), String.replace(e, "&quot;", "\"")} end)
    reply(conn, Server.update(s, &S3.complete_multipart(&1, id, parts, %{min_part: Keyword.get(o, :min_part, 5 * 1024 * 1024)})), fn obj ->
      xml(conn, 200, ~s(<CompleteMultipartUploadResult><Bucket>#{esc(b)}</Bucket><Key>#{esc(k)}</Key><ETag>#{esc(obj.etag)}</ETag></CompleteMultipartUploadResult>))
    end)
  end

  defp object(conn, "PUT", _b, _k, %{"uploadId" => id, "partNumber" => n}, body, s, _o) do
    reply(conn, Server.update(s, &S3.upload_part(&1, id, String.to_integer(n), body)), fn e -> send_resp(put_resp_header(conn, "etag", e), 200, "") end)
  end

  defp object(conn, "DELETE", _b, _k, %{"uploadId" => id}, _body, s, _o), do: reply(conn, Server.update(s, &S3.abort_multipart(&1, id)), fn _ -> send_resp(conn, 204, "") end)

  defp object(conn, "PUT", b, k, _q, body, s, _o) do
    opts = %{if_match: hdr(conn, "if-match"), if_none_match: hdr(conn, "if-none-match"), content_type: hdr(conn, "content-type")}
    reply(conn, Server.update(s, &S3.put_object(&1, b, k, body, opts)), fn o -> send_resp(put_resp_header(conn, "etag", o.etag), 200, "") end)
  end

  defp object(conn, m, b, k, _q, _body, s, _o) when m in ["GET", "HEAD"] do
    reply(conn, Server.read(s, &S3.get_object(&1, b, k)), fn o ->
      inm = hdr(conn, "if-none-match")
      im = hdr(conn, "if-match")

      conn =
        conn
        |> put_resp_header("etag", o.etag)
        |> put_resp_header("content-type", o.content_type)
        |> put_resp_header("last-modified", Calendar.strftime(o.modified, "%a, %d %b %Y %H:%M:%S GMT"))

      cond do
        im && im != o.etag -> error(conn, 412, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold")
        inm && inm == o.etag -> send_resp(conn, 304, "")
        m == "HEAD" -> conn |> put_resp_header("content-length", Integer.to_string(o.size)) |> send_resp(200, "")
        true -> send_resp(conn, 200, o.body)
      end
    end, m == "HEAD")
  end

  defp object(conn, "DELETE", b, k, _q, _body, s, _o) do
    opts = %{if_match: hdr(conn, "if-match")}
    reply(conn, Server.update(s, &S3.delete_object(&1, b, k, opts)), fn _ -> send_resp(conn, 204, "") end)
  end

  defp object(conn, _, _, _, _, _, _, _), do: error(conn, 405, "MethodNotAllowed", "The specified method is not allowed against this resource.")

  defp reply(conn, res, ok, head? \\ false)
  defp reply(conn, {:error, e}, _ok, head?), do: if(head?, do: send_resp(conn, e.status, ""), else: error(conn, e.status, e.code, e.message))
  defp reply(_conn, {:ok, v}, ok, _), do: ok.(v)
  defp reply(_conn, :ok, ok, _), do: ok.(nil)
  defp reply(_conn, v, ok, _), do: ok.(v)

  defp hdr(conn, n), do: List.first(get_req_header(conn, n))

  defp xml(conn, status, body), do: conn |> put_resp_content_type("application/xml") |> send_resp(status, ~s(<?xml version="1.0" encoding="UTF-8"?>) <> body)
  def error(conn, status, code, msg), do: xml(conn, status, "<Error><Code>#{code}</Code><Message>#{esc(msg)}</Message></Error>")

  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

  defp list_buckets_xml(bs), do: "<ListAllMyBucketsResult><Buckets>" <> Enum.map_join(bs, fn {n, t} -> "<Bucket><Name>#{esc(n)}</Name><CreationDate>#{DateTime.to_iso8601(t)}</CreationDate></Bucket>" end) <> "</Buckets></ListAllMyBucketsResult>"

  defp list_xml(b, q, r) do
    items = Enum.map_join(r.entries, fn
      {:prefix, p} -> "<CommonPrefixes><Prefix>#{esc(p)}</Prefix></CommonPrefixes>"
      {:object, k, o} -> "<Contents><Key>#{esc(k)}</Key><ETag>#{esc(o.etag)}</ETag><Size>#{o.size}</Size></Contents>"
    end)
    tok = if r.next, do: "<NextContinuationToken>#{esc(r.next)}</NextContinuationToken>", else: ""
    "<ListBucketResult><Name>#{esc(b)}</Name><Prefix>#{esc(q["prefix"] || "")}</Prefix><KeyCount>#{length(r.entries)}</KeyCount><IsTruncated>#{r.truncated}</IsTruncated>#{tok}#{items}</ListBucketResult>"
  end
end
