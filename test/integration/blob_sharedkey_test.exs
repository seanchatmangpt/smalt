defmodule Smalt.Integration.BlobSharedKeyTest do
  @moduledoc """
  KD-114 close court (lane W20-B): blob SharedKey admit — Chicago-style,
  real collaborators (real bearer plug + real egress router + real ETS blob
  store), assert on final wire state.

  The signature helper is an INDEPENDENT construction of the 2021-12-02 blob
  StringToSign from the Azure SharedKey spec — not a call into the module
  under test — so the court is not tautological.
  """
  use ExUnit.Case, async: false

  @account "popcorn"
  @key_b64 Base.encode64(:crypto.hash(:sha256, @account <> "smalt-dev-sb"))

  setup do
    prev = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :enforce)
    on_exit(fn -> Application.put_env(:smalt, :auth_mode, prev) end)
    :ok
  end

  defp call(method, path, query, headers, body) do
    full = if query in [nil, ""], do: path, else: path <> "?" <> query
    conn = Plug.Test.conn(method, full, body)

    conn =
      if body in [nil, ""] do
        conn
      else
        conn |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body)))
      end

    sign_headers =
      if body in [nil, ""] do
        headers
      else
        headers ++ [{"content-length", Integer.to_string(byte_size(body))}]
      end

    conn = Enum.reduce(sign_headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    auth = authorization(method, path, query, sign_headers)

    conn
    |> Plug.Conn.put_req_header("authorization", auth)
    |> Smalt.Auth.Bearer.call(nil)
    |> Smalt.EgressRouter.call(nil)
  end

  defp independent_sign(method, path, query, headers) do
    hdr = fn name ->
      case Enum.filter(headers, fn {k, _} -> k == name end) do
        [{_, v} | _] -> v
        [] -> ""
      end
    end

    cl =
      case hdr.("content-length") do
        "" -> ""
        "0" -> ""
        len -> len
      end

    standard = [
      method,
      hdr.("content-encoding"),
      hdr.("content-language"),
      cl,
      hdr.("content-md5"),
      hdr.("content-type"),
      if(hdr.("x-ms-date") != "", do: "", else: hdr.("date")),
      hdr.("if-modified-since"),
      hdr.("if-match"),
      hdr.("if-none-match"),
      hdr.("if-unmodified-since"),
      hdr.("range")
    ]

    canon_headers =
      headers
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-ms-") end)
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
      |> Enum.map(fn {k, v} -> "#{k}:#{v}\n" end)
      |> Enum.join()

    canon_resource = "/" <> @account <> path <> sign_query(query)

    Enum.join(standard, "\n") <> "\n" <> canon_headers <> canon_resource
  end

  defp sign_query(nil), do: ""
  defp sign_query(""), do: ""

  defp sign_query(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [n] -> {n, ""}
        [n, v] -> {n, v}
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> String.downcase(a) <= String.downcase(b) end)
    |> Enum.map(fn {n, v} -> "\n" <> String.downcase(n) <> ":" <> v end)
    |> Enum.join()
  end

  defp authorization(method, path, query, headers, key_b64 \\ :primary) do
    key = key_material(key_b64)
    sts = independent_sign(method, path, query, headers)
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, sts))
    "SharedKey " <> @account <> ":" <> sig
  end

  defp key_material(:primary), do: Base.decode64!(@key_b64)
  defp key_material(other_b64) when is_binary(other_b64), do: Base.decode64!(other_b64)

  defp xms do
    [
      {"x-ms-version", "2021-12-02"},
      {"x-ms-date", "Tue, 20 Oct 2026 00:00:00 GMT"}
    ]
  end

  test "valid SharedKey round trip: create container 201, PUT blob 201, GET blob 200 byte-equal" do
    unique = System.unique_integer([:positive])
    path = "/#{@account}/kd114-court-#{unique}"
    blob_path = path <> "/kd114-court-blob-#{unique}.txt"
    payload = "kd114-court-bytes-#{unique}"

    create = call("PUT", path, "restype=container", xms(), nil)
    assert create.status == 201

    put = call("PUT", blob_path, "", xms() ++ [{"x-ms-blob-type", "BlockBlob"}], payload)
    assert put.status == 201

    get = call("GET", blob_path, "", xms(), nil)
    assert get.status == 200
    assert IO.iodata_to_binary(get.resp_body) == payload
  end

  test "tampered signature refuses 401 typed AuthenticationFailed" do
    unique = System.unique_integer([:positive])
    path = "/#{@account}/kd114-court-#{unique}"
    good = authorization("PUT", path, "restype=container", xms())
    tampered = "SharedKey " <> @account <> ":" <> tamper(good_sig(good))

    conn = call_raw("PUT", path <> "?restype=container", xms(), tampered)

    assert conn.status == 401

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "AuthenticationFailed"
  end

  test "wrong account key refuses 401 AuthenticationFailed" do
    unique = System.unique_integer([:positive])
    path = "/#{@account}/kd114-court-#{unique}"
    wrong_key = Base.encode64(:crypto.hash(:sha256, "not-the-key"))

    bad = authorization("PUT", path, "restype=container", xms(), wrong_key)

    conn = call_raw("PUT", path <> "?restype=container", xms(), bad)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "AuthenticationFailed"
  end

  defp good_sig(auth) do
    "SharedKey " <> @account <> ":" <> sig = auth
    sig
  end

  defp tamper(sig) do
    first = String.first(sig)

    flipped =
      case first do
        "A" -> "B"
        _ -> "A"
      end

    flipped <> String.slice(sig, 1..-1//1)
  end

  defp call_raw(method, path_with_query, headers, auth) do
    conn = Plug.Test.conn(method, path_with_query)

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    conn
    |> Plug.Conn.put_req_header("authorization", auth)
    |> Smalt.Auth.Bearer.call(nil)
    |> Smalt.EgressRouter.call(nil)
  end
end
