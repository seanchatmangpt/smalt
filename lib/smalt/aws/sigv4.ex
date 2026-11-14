defmodule Smalt.AWS.SigV4 do
  @moduledoc """
  AWS Signature V4 helper (AS1): `sign/1` produces an Authorization header,
  `verify/3` re-signs a `Plug.Conn` and compares in constant time.
  Pure; S3 mode (`service: "s3"`) does not double-encode the path.
  Creds lookup: `%{access_key_id => secret}` map or 1-arity fun.
  """
  import Bitwise

  @alg "AWS4-HMAC-SHA256"

  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp hmac(k, d), do: :crypto.mac(:hmac, :sha256, k, d)

  def uri_encode(s, encode_slash? \\ true) do
    for <<c <- s>>, into: "" do
      cond do
        c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?-, ?_, ?., ?~] -> <<c>>
        c == ?/ and not encode_slash? -> "/"
        true -> "%" <> Base.encode16(<<c>>)
      end
    end
  end

  def canonical_query(qs) when is_binary(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn kv ->
      {k, v} =
        case String.split(kv, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end

      {uri_encode(URI.decode(k |> String.replace("+", "%20"))),
       uri_encode(URI.decode(v |> String.replace("+", "%20")))}
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> k <> "=" <> v end)
  end

  def signing_key(secret, date, region, service) do
    ("AWS4" <> secret) |> hmac(date) |> hmac(region) |> hmac(service) |> hmac("aws4_request")
  end

  @doc "Canonical request string. `headers` is a list of {lowercase_name, value}."
  def canonical_request(method, path, query, headers, signed, payload_hash, service) do
    path = if service == "s3", do: encode_path(path), else: encode_path(encode_path(path))

    ch =
      Enum.map_join(signed, "", fn n ->
        v = headers |> Enum.filter(fn {k, _} -> k == n end) |> Enum.map_join(",", fn {_, v} -> collapse(v) end)
        n <> ":" <> v <> "\n"
      end)

    Enum.join([method, path, canonical_query(query), ch, Enum.join(signed, ";"), payload_hash], "\n")
  end

  defp encode_path(p), do: p |> String.split("/") |> Enum.map_join("/", &uri_encode(URI.decode(&1)))
  defp collapse(v), do: v |> String.trim() |> String.replace(~r/\s+/, " ")

  def string_to_sign(amz_date, scope, canonical) do
    Enum.join([@alg, amz_date, scope, sha256_hex(canonical)], "\n")
  end

  @doc """
  Sign. opts: method, path (raw), query, headers (list, incl. host), body,
  access_key_id, secret, region, service, amz_date ("20260101T000000Z").
  Returns the Authorization header value.
  """
  def sign(o) do
    headers = Enum.map(o.headers, fn {k, v} -> {String.downcase(k), v} end)
    signed = headers |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    ph = Map.get(o, :payload_hash) || sha256_hex(Map.get(o, :body, ""))
    date = binary_part(o.amz_date, 0, 8)
    scope = "#{date}/#{o.region}/#{o.service}/aws4_request"
    cr = canonical_request(o.method, o.path, Map.get(o, :query, ""), headers, signed, ph, o.service)
    sig = signing_key(o.secret, date, o.region, o.service) |> hmac(string_to_sign(o.amz_date, scope, cr)) |> Base.encode16(case: :lower)
    "#{@alg} Credential=#{o.access_key_id}/#{scope}, SignedHeaders=#{Enum.join(signed, ";")}, Signature=#{sig}"
  end

  def parse_auth("AWS4-HMAC-SHA256 " <> rest) do
    kv = rest |> String.split(",") |> Map.new(fn p -> p |> String.trim() |> String.split("=", parts: 2) |> List.to_tuple() end)

    with %{"Credential" => cred, "SignedHeaders" => sh, "Signature" => sig} <- kv,
         [akid, date, region, service, "aws4_request"] <- String.split(cred, "/") do
      {:ok, %{akid: akid, date: date, region: region, service: service, signed: String.split(sh, ";"), signature: sig}}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse_auth(_), do: {:error, :malformed}

  @doc "Verify a conn. Returns {:ok, akid} | {:error, :missing|:malformed|:unknown_key|:mismatch}."
  def verify(conn, body, creds) do
    with [auth] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, p} <- parse_auth(auth),
         {:ok, secret} <- lookup(creds, p.akid),
         [amz_date] <- Plug.Conn.get_req_header(conn, "x-amz-date") do
      hdrs = for {k, v} <- conn.req_headers, do: {String.downcase(k), v}
      ph = case Plug.Conn.get_req_header(conn, "x-amz-content-sha256") do
        [h] -> h
        _ -> sha256_hex(body)
      end
      scope = "#{p.date}/#{p.region}/#{p.service}/aws4_request"
      cr = canonical_request(conn.method, conn.request_path, conn.query_string, hdrs, p.signed, ph, p.service)
      expected = signing_key(secret, p.date, p.region, p.service) |> hmac(string_to_sign(amz_date, scope, cr)) |> Base.encode16(case: :lower)
      if const_eq(expected, p.signature), do: {:ok, p.akid}, else: {:error, :mismatch}
    else
      [] -> {:error, :missing}
      {:error, _} = e -> e
      :error -> {:error, :unknown_key}
      _ -> {:error, :malformed}
    end
  end

  defp lookup(m, k) when is_map(m), do: Map.fetch(m, k)
  defp lookup(f, k) when is_function(f, 1), do: f.(k)

  defp const_eq(a, b) when byte_size(a) == byte_size(b) do
    a |> :binary.bin_to_list() |> Enum.zip(:binary.bin_to_list(b)) |> Enum.reduce(0, fn {x, y}, acc -> acc ||| bxor(x, y) end) == 0
  end

  defp const_eq(_, _), do: false
end
