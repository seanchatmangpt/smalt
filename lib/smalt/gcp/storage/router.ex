defmodule Smalt.GCP.Storage.Router do
  @moduledoc """
  GCS wire face: JSON API (`/storage/v1/b/...`), upload API
  (`/upload/storage/v1/b/:b/o`, `/upload/resumable/:id`) and XML API
  (path-style `/:bucket/:object` or host-style `bucket.storage.googleapis.com`).
  A plain Plug; `Smalt.GCP.Storage.Server` holds state. Options:
  `:server` (default `Smalt.GCP.Storage.Server`), `:signing_key` (enables
  signed-URL verification on XML GET/HEAD when `X-Goog-Signature` is present).
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.GCP.Storage, as: S
  alias Smalt.GCP.Storage.Server

  @max_body 512 * 1024 * 1024

  def init(opts), do: opts

  def call(conn, opts) do
    conn = fetch_query_params(conn)
    segs = conn.request_path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)
    srv = Keyword.get(opts, :server, Server)
    host_bucket = host_bucket(conn)

    case route(conn.method, segs, host_bucket) do
      {:json, fun} -> fun.(conn, srv)
      {:xml, bucket, obj} -> xml(conn, srv, bucket, obj, opts)
      :nomatch -> send_err(conn, S.err(404, "notFound", "Not Found") |> elem(1))
    end
  end

  # ---- routing table -----------------------------------------------------
  defp route("POST", ["storage", "v1", "b"], _), do: {:json, &create_bucket/2}
  defp route("GET", ["storage", "v1", "b"], _), do: {:json, &list_buckets/2}
  defp route("GET", ["storage", "v1", "b", b], _), do: {:json, &with_b(&1, &2, b, :get_bucket)}
  defp route("DELETE", ["storage", "v1", "b", b], _), do: {:json, &with_b(&1, &2, b, :del_bucket)}
  defp route("GET", ["storage", "v1", "b", b, "o"], _), do: {:json, &list_objects(&1, &2, b)}
  defp route("GET", ["storage", "v1", "b", b, "o", o], _), do: {:json, &get_object(&1, &2, b, o)}
  defp route("DELETE", ["storage", "v1", "b", b, "o", o], _), do: {:json, &del_object(&1, &2, b, o)}
  defp route("POST", ["storage", "v1", "b", b, "o", o, "compose"], _), do: {:json, &compose(&1, &2, b, o)}
  defp route("POST", ["upload", "storage", "v1", "b", b, "o"], _), do: {:json, &upload(&1, &2, b)}
  defp route("PUT", ["upload", "resumable", id], _), do: {:json, &resume(&1, &2, id)}
  defp route(m, [b | rest], nil) when m in ~w(GET HEAD PUT DELETE) and b not in ["storage", "upload"] and rest != [],
    do: {:xml, b, Enum.join(rest, "/")}
  defp route(m, rest, hb) when is_binary(hb) and m in ~w(GET HEAD PUT DELETE) and rest != [],
    do: {:xml, hb, Enum.join(rest, "/")}
  defp route(_, _, _), do: :nomatch

  defp host_bucket(conn) do
    case String.split(conn.host || "", ".storage.googleapis.com", parts: 2) do
      [b, ""] when b != "" -> b
      _ -> nil
    end
  end

  # ---- JSON handlers -----------------------------------------------------
  defp create_bucket(conn, srv) do
    {:ok, body, conn} = read_json(conn)
    reply(conn, Server.call(srv, &S.create_bucket(&1, body["name"], body)))
  end

  defp list_buckets(conn, srv) do
    {:ok, l} = Server.call(srv, fn st -> {:ok, st, elem(S.list_buckets(st), 1)} end)
    reply(conn, {:ok, %{"kind" => "storage#buckets", "items" => l}})
  end

  defp with_b(conn, srv, b, :get_bucket), do: reply(conn, Server.call(srv, fn st -> with {:ok, x} <- S.get_bucket(st, b), do: {:ok, st, x} end))
  defp with_b(conn, srv, b, :del_bucket), do: reply(conn, Server.call(srv, &S.delete_bucket(&1, b)), 204)

  defp list_objects(conn, srv, b) do
    r = Server.call(srv, fn st -> with {:ok, x} <- S.list_objects(st, b, conn.query_params), do: {:ok, st, x} end)

    case r do
      {:ok, %{items: i, prefixes: p}} ->
        reply(conn, {:ok, %{"kind" => "storage#objects", "items" => Enum.map(i, &S.object_json/1), "prefixes" => p}})
      e -> reply(conn, e)
    end
  end

  defp get_object(conn, srv, b, o) do
    case Server.call(srv, fn st -> with {:ok, x} <- S.get_object(st, b, o, conn.query_params), do: {:ok, st, x} end) do
      {:ok, obj} ->
        if conn.query_params["alt"] == "media", do: send_media(conn, obj, true), else: reply(conn, {:ok, S.object_json(obj)})
      e -> reply(conn, e)
    end
  end

  defp del_object(conn, srv, b, o), do: reply(conn, Server.call(srv, &S.delete_object(&1, b, o, conn.query_params)), 204)

  defp compose(conn, srv, b, dest) do
    {:ok, body, conn} = read_json(conn)
    meta = body["destination"] || %{}
    r = Server.call(srv, &S.compose(&1, b, dest, body["sourceObjects"] || [], meta, conn.query_params))
    reply(conn, map_obj(r))
  end

  defp upload(conn, srv, b) do
    q = conn.query_params
    pre = q

    case q["uploadType"] do
      "media" ->
        {:ok, data, conn} = read_all(conn)
        meta = %{"contentType" => hd(get_req_header(conn, "content-type") ++ ["application/octet-stream"])}
        reply(conn, map_obj(Server.call(srv, &S.put_object(&1, b, q["name"], data, meta, pre))))

      "multipart" ->
        {:ok, raw, conn} = read_all(conn)
        case multipart(conn, raw) do
          {:ok, meta, data} ->
            reply(conn, map_obj(Server.call(srv, &S.put_object(&1, b, meta["name"] || q["name"], data, meta, pre))))
          :error -> send_err(conn, S.err(400, "invalid", "Malformed multipart upload") |> elem(1))
        end

      "resumable" ->
        {:ok, meta, conn} = read_json(conn)
        name = meta["name"] || q["name"]
        case Server.call(srv, &S.start_resumable(&1, b, name, meta, pre)) do
          {:ok, id} ->
            loc = "#{conn.scheme}://#{conn.host}:#{conn.port}/upload/resumable/#{id}"
            conn |> put_resp_header("location", loc) |> send_resp(200, "")
          e -> reply(conn, e)
        end

      _ -> send_err(conn, S.err(400, "invalid", "Invalid uploadType") |> elem(1))
    end
  end

  defp resume(conn, srv, id) do
    {:ok, chunk, conn} = read_all(conn)
    range = conn |> get_req_header("content-range") |> List.first() |> then(&S.parse_content_range(&1 || "bytes */*"))

    if range == :error do
      send_err(conn, S.err(400, "invalid", "Bad Content-Range") |> elem(1))
    else
      case Server.call(srv, &S.upload_chunk(&1, id, chunk, range)) do
        {:incomplete, n} ->
          conn = if n > 0, do: put_resp_header(conn, "range", "bytes=0-#{n - 1}"), else: conn
          send_resp(conn, 308, "")
        r -> reply(conn, map_obj(r))
      end
    end
  end

  # ---- XML API -----------------------------------------------------------
  defp xml(conn, srv, b, o, opts) do
    q = conn.query_params

    with :ok <- check_signed(conn, q, opts) do
      case conn.method do
        m when m in ["GET", "HEAD"] ->
          case Server.call(srv, fn st -> with {:ok, x} <- S.get_object(st, b, o, q), do: {:ok, st, x} end) do
            {:ok, obj} -> send_media(conn, obj, m == "GET")
            {:error, e} -> xml_err(conn, e)
          end

        "PUT" ->
          {:ok, data, conn} = read_all(conn)
          pre = ifgen_from_header(conn, q)
          meta = %{"contentType" => hd(get_req_header(conn, "content-type") ++ ["application/octet-stream"])}
          case Server.call(srv, &S.put_object(&1, b, o, data, meta, pre)) do
            {:ok, obj} -> conn |> put_resp_header("x-goog-generation", to_string(obj.generation)) |> put_resp_header("etag", "\"" <> Base.encode16(:crypto.hash(:md5, data), case: :lower) <> "\"") |> send_resp(200, "")
            {:error, e} -> xml_err(conn, e)
          end

        "DELETE" ->
          case Server.call(srv, &S.delete_object(&1, b, o, ifgen_from_header(conn, q))) do
            :ok -> send_resp(conn, 204, "")
            {:error, e} -> xml_err(conn, e)
          end
      end
    else
      {:error, e} -> xml_err(conn, e)
    end
  end

  defp ifgen_from_header(conn, q) do
    case get_req_header(conn, "x-goog-if-generation-match") do
      [v | _] -> Map.put(q, "ifGenerationMatch", v)
      _ -> q
    end
  end

  defp check_signed(conn, q, opts) do
    case {Keyword.get(opts, :signing_key), q["X-Goog-Signature"]} do
      {key, sig} when is_binary(key) and is_binary(sig) -> S.verify_signed(conn.method, conn.request_path, q, key)
      _ -> :ok
    end
  end

  defp xml_err(conn, %{status: s, reason: r, message: m}) do
    body = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>#{r}</Code><Message>#{Plug.HTML.html_escape(m)}</Message></Error>"
    conn |> put_resp_content_type("application/xml") |> send_resp(s, body)
  end

  # ---- helpers -----------------------------------------------------------
  defp send_media(conn, obj, body?) do
    conn =
      conn
      |> put_resp_header("content-type", obj.content_type)
      |> put_resp_header("x-goog-generation", to_string(obj.generation))
      |> put_resp_header("x-goog-metageneration", to_string(obj.metageneration))
      |> put_resp_header("x-goog-hash", "crc32c=#{obj.crc32c},md5=#{obj.md5}")

    data = obj.data
    case get_req_header(conn, "range") do
      ["bytes=" <> r] when body? ->
        with [a, z] <- String.split(r, "-", parts: 2), {a, ""} <- Integer.parse(a) do
          z = case Integer.parse(z), do: ({n, ""} -> min(n, byte_size(data) - 1); _ -> byte_size(data) - 1)
          conn |> put_resp_header("content-range", "bytes #{a}-#{z}/#{byte_size(data)}") |> send_resp(206, binary_part(data, a, max(z - a + 1, 0)))
        else
          _ -> send_resp(conn, 200, data)
        end
      _ ->
        conn = put_resp_header(conn, "content-length", to_string(byte_size(data)))
        send_resp(conn, 200, if(body?, do: data, else: ""))
    end
  end

  defp map_obj({:ok, obj}), do: {:ok, S.object_json(obj)}
  defp map_obj(other), do: other

  defp reply(conn, r, ok_status \\ 200)
  defp reply(conn, {:ok, body}, st), do: json(conn, st, body)
  defp reply(conn, :ok, st), do: send_resp(conn, st, "")
  defp reply(conn, {:error, e}, _), do: send_err(conn, e)

  defp send_err(conn, e), do: json(conn, e.status, S.error_json(e))

  defp json(conn, status, body), do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp read_all(conn) do
    case read_body(conn, length: @max_body, read_length: 8_000_000) do
      {:ok, b, c} -> {:ok, b, c}
      {:more, b, c} -> read_more(c, [b])
    end
  end

  defp read_more(conn, acc) do
    case read_body(conn, length: @max_body, read_length: 8_000_000) do
      {:ok, b, c} -> {:ok, IO.iodata_to_binary(Enum.reverse([b | acc])), c}
      {:more, b, c} -> read_more(c, [b | acc])
    end
  end

  defp read_json(conn) do
    {:ok, b, conn} = read_all(conn)
    case b != "" && Jason.decode(b) do
      {:ok, m} when is_map(m) -> {:ok, m, conn}
      _ -> {:ok, %{}, conn}
    end
  end

  defp multipart(conn, raw) do
    with [ct | _] <- get_req_header(conn, "content-type"),
         [_, boundary] <- Regex.run(~r/boundary="?([^";]+)"?/, ct),
         [_, p1, p2 | _] <- String.split(raw, "--" <> boundary),
         {:ok, meta} <- Jason.decode(part_body(p1)) do
      data = part_body(p2)
      meta = if ct2 = part_ct(p2), do: Map.put_new(meta, "contentType", ct2), else: meta
      {:ok, meta, data}
    else
      _ -> :error
    end
  end

  defp part_body(p) do
    case String.split(p, "\r\n\r\n", parts: 2) do
      [_, body] -> String.replace_suffix(body, "\r\n", "")
      _ -> ""
    end
  end

  defp part_ct(p) do
    case Regex.run(~r/content-type:\s*([^\r\n]+)/i, p) do
      [_, ct] -> ct
      _ -> nil
    end
  end
end
