defmodule Smalt.Integration.BlobSharedKeyNotReadyTest do
  @moduledoc """
  POP500 regression court: the auth seam answers a SharedKey-authenticated
  request with a TYPED face, never a raw 500.

  Witnessed live on the 9444 TLS shared substrate: a stale default build root
  left `Smalt.Auth.SharedKey` unloadable at boot and `Smalt.Auth.Bearer.call/2`
  delegated to it unguarded: every SharedKey request raised
  UndefinedFunctionError -> RestError 500, FATALing the popcorn_demo
  BACKEND=smalt dual-mode harness (VERIFY2 + KVLEG receipts). Fix under test:
  the delegation is guarded (`Code.ensure_loaded?/1`); when the verifier is
  not loadable the seam answers the router's typed 503 RouteNotReady face
  (same class as `EgressRouter.route_not_ready/1`, incl. Retry-After).

  Chicago: real plug + real router + real ETS store, asserts on final wire
  state. No mocks.
  """

  use ExUnit.Case, async: false

  @account "popcorn"
  @key_b64 Base.encode64(:crypto.hash(:sha256, @account <> "smalt-dev-sb"))

  setup do
    prev = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :enforce)
    on_exit(fn ->
      Application.put_env(:smalt, :auth_mode, prev)
      :ok
    end)

    :ok
  end

  test "valid SharedKey signature admits through the guarded seam (201/409)" do
    conn = call("PUT", "/popcorn/#{container()}", "restype=container", base_headers(), "")

    assert conn.status in [201, 409],
           "expected 201 (or 409 on rerun), got #{conn.status}: #{conn.resp_body}"
  end

  test "tampered SharedKey signature is the typed 401, not a 500" do
    conn =
      call("PUT", "/popcorn/#{container()}", "restype=container", base_headers(), "",
        key_b64: Base.encode64(:crypto.hash(:sha256, "tampered-" <> @account)))

    assert conn.status == 401
    assert conn.resp_body =~ "AuthenticationFailed"
    assert www_authenticate_present?(conn)
  end

  test "guard is present at the delegation seam (structural non-vacuity)" do
    src = File.read!(Path.join([__DIR__, "..", "..", "lib", "smalt", "auth", "bearer.ex"]))

    assert src =~ "Code.ensure_loaded?(Smalt.Auth.SharedKey)",
           "SharedKey delegation lost its not-ready guard (POP500 regression)"

    assert src =~ "{:not_ready, code, reason} -> not_ready(conn, code, reason)",
           "admission/1 no longer routes {:not_ready, ..} to the typed 503 face"
  end

  # -- helpers ----------------------------------------------------------------

  defp container, do: "pop500-" <> Integer.to_string(System.unique_integer([:positive]))

  defp base_headers do
    [
      {"x-ms-version", "2021-12-02"},
      {"x-ms-date", "Tue, 20 Oct 2026 00:00:00 GMT"}
    ]
  end

  defp call(method, path, query, headers, body, opts \\ []) do
    key = Keyword.get(opts, :key_b64, :primary)
    full = if query in [nil, ""], do: path, else: path <> "?" <> query
    conn = Plug.Test.conn(method, full, body)

    conn =
      if body in [nil, ""], do: conn, else: put_content_length(conn, body)

    sign_headers = headers ++ content_length_header(body)

    conn = Enum.reduce(sign_headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    conn
    |> Plug.Conn.put_req_header("authorization", authorization(method, path, query, sign_headers, key))
    |> Smalt.Auth.Bearer.call(nil)
    |> Smalt.EgressRouter.call(nil)
  end

  defp put_content_length(conn, body),
    do: Plug.Conn.put_req_header(conn, "content-length", Integer.to_string(byte_size(body)))

  defp content_length_header(body) when byte_size(body) > 0,
    do: [{"content-length", Integer.to_string(byte_size(body))}]

  defp content_length_header(_), do: []

  defp www_authenticate_present?(conn) do
    conn |> Plug.Conn.get_resp_header("www-authenticate") |> List.first() |> is_binary()
  end

  # Independent construction of the 2021-12-02 SharedKey StringToSign from the
  # Azure spec (not a call into the module under test) — byte-grammar copied
  # from Smalt.Integration.BlobSharedKeyTest's independent_sign/4.
  defp authorization(method, path, query, headers, key_b64 \\ :primary) do
    hdr = fn name ->
      case Enum.filter(headers, fn {k, _} -> k == name end) do
        [{_, v} | _] -> v
        [] -> ""
      end
    end

    standard = [
      method,
      hdr.("content-encoding"),
      hdr.("content-language"),
      hdr.("content-length"),
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
    sts = Enum.join(standard, "\n") <> "\n" <> canon_headers <> canon_resource

    key =
      case key_b64 do
        :primary -> Base.decode64!(@key_b64)
        other -> Base.decode64!(other)
      end

    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, sts))
    "SharedKey " <> @account <> ":" <> sig
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
end
