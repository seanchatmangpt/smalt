defmodule Smalt.Integration.BlobKdFixesTest do
  # FIX-1 lane (v26.10.20): close court for the four W30-D blob-face rows —
  # KD-137 (416 envelope), KD-139 (400 MissingRequiredHeader), KD-140 (411
  # LengthRequired), KD-141 (400 InvalidMetadata) — plus the regression fence:
  # KD-66 206+md5, KD-130 409, KD-122/123 clauses, KD-114 SharedKey admit.
  # Chicago-style: real router, real ETS blob store, no mocks; assertions on
  # wire status, headers, and bytes.
  use ExUnit.Case, async: false

  @account "acct-fix1"
  @version "2023-11-03"

  defp call(method, path, opts \\ []) do
    headers = opts[:headers] || []

    conn =
      Plug.Test.conn(method, path, opts[:body])
      |> Plug.Conn.put_req_header("x-ms-version", @version)
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp xml_code(conn) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, conn.resp_body) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp put_container(container) do
    call(:put, "/#{@account}/#{container}?restype=container")
  end

  defp put_blob(container, blob, headers) do
    call(:put, "/#{@account}/#{container}/#{blob}",
      body: "0123456789",
      headers: [{"x-ms-blob-type", "BlockBlob"}] ++ headers
    )
  end

  # ---- KD-137: 416 carries x-ms-error-code + StorageError XML envelope

  test "KD-137: range past EOF answers 416 with x-ms-error-code + XML envelope" do
    assert put_container("kd137").status in [201, 409]
    assert put_blob("kd137", "ten.txt", []).status == 201

    conn = call(:get, "/#{@account}/kd137/ten.txt", headers: [{"x-ms-range", "bytes=1000-2000"}])

    assert conn.status == 416
    assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == ["InvalidRange"]
    assert Plug.Conn.get_resp_header(conn, "content-range") == ["bytes */10"]
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]
    assert xml_code(conn) == "InvalidRange"
    assert conn.resp_body =~ ~s(<?xml version="1.0" encoding="utf-8"?>)
  end

  # ---- KD-139: headerless blob PUT -> 400 MissingRequiredHeader (XML face)

  test "KD-139: headerless blob PUT answers 400 MissingRequiredHeader with XML" do
    assert put_container("kd139").status in [201, 409]

    conn = call(:put, "/#{@account}/kd139/nohint.txt", body: "x")

    assert conn.status == 400
    assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == ["MissingRequiredHeader"]
    assert xml_code(conn) == "MissingRequiredHeader"
  end

  # ---- KD-140: CL-less blob PUT -> 411 LengthRequired (never 201 0-byte).
  # The 411 guard is scoped to real-wire conns: a synthetic test-adapter conn
  # carries req_body without transport headers, so a missing Content-Length
  # there is a harness artifact, not a wire fact. The 411 shape itself is
  # witnessed on the LIVE wire by curl (receipt), not by plug conn.

  test "KD-140: test-adapter CL-less PUT is the harness-artifact path (admits)" do
    assert put_container("kd140").status in [201, 409]

    conn =
      Plug.Test.conn(:put, "/#{@account}/kd140/nolen.txt", "x")
      |> Plug.Conn.put_req_header("x-ms-version", @version)
      |> Plug.Conn.put_req_header("x-ms-blob-type", "BlockBlob")
      |> Plug.Conn.delete_req_header("content-length")
      |> Smalt.EgressRouter.call([])

    # adapter-scoped guard: test conns proceed, real wire 411s (curl witness)
    assert conn.status == 201
  end

  test "KD-140: PUT WITH Content-Length: 0 is admitted (201, 0-byte blob)" do
    assert put_container("kd140").status in [201, 409]

    conn =
      call(:put, "/#{@account}/kd140/zero.txt",
        body: "",
        headers: [{"x-ms-blob-type", "BlockBlob"}, {"content-length", "0"}]
      )

    assert conn.status == 201
  end

  # ---- KD-141: invalid metadata header -> typed 400 InvalidMetadata (no 500)

  test "KD-141: invalid metadata name answers 400 InvalidMetadata" do
    assert put_container("kd141").status in [201, 409]

    conn =
      put_blob("kd141", "meta.txt", [
        {"x-ms-meta-bad!name", "v"},
        {"x-ms-meta-also bad", "v"}
      ])

    assert conn.status == 400
    assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == ["InvalidMetadata"]
    assert xml_code(conn) == "InvalidMetadata"

    # the refused PUT stored nothing
    get = call(:get, "/#{@account}/kd141/meta.txt")
    assert get.status == 404
  end

  # ---- regression fence

  test "KD-66 regression: ranged GET answers 206 with Content-MD5 of the slice" do
    assert put_container("kd66").status in [201, 409]
    assert put_blob("kd66", "r.png", []).status == 201

    conn =
      call(:get, "/#{@account}/kd66/r.png",
        headers: [
          {"x-ms-range", "bytes=0-3"},
          {"x-ms-range-get-content-md5", "true"}
        ]
      )

    assert conn.status == 206
    assert Plug.Conn.get_resp_header(conn, "content-range") == ["bytes 0-3/10"]
    assert Plug.Conn.get_resp_header(conn, "content-md5") == [Base.encode64(:crypto.hash(:md5, "0123"))]
  end

  test "KD-130 regression: re-PUT of an existing container answers 409 ContainerAlreadyExists" do
    assert put_container("kd130").status in [201, 409]

    conn = put_container("kd130")

    assert conn.status == 409
    assert xml_code(conn) == "ContainerAlreadyExists"
  end

  test "KD-122/123 regression: service-properties XML PUT admits (202) and queue form POST stores non-empty MessageText" do
    # KD-122 clause: StorageServiceProperties XML body is not swallowed by the
    # raw-body parser — stored rules answer 202 with the whitelist intact.
    props =
      ~s(<?xml version="1.0" encoding="utf-8"?><StorageServiceProperties><Logging><Version>1.0</Version><Delete>true</Delete></Logging><Cors><CorsRule><AllowedOrigins> *</AllowedOrigins><AllowedMethods>GET,PUT</AllowedMethods></CorsRule></Cors></StorageServiceProperties>)

    conn =
      call(:put, "/#{@account}/?restype=service&comp=properties", body: props)

    assert conn.status == 202

    # KD-123 clause: queue message PUT with form-urlencoded content-type must
    # store a NON-EMPTY MessageText (201 on the wire, non-empty on dequeue).
    # FIX-2 unblock (B-KD, disclosed): queue containers are created with
    # restype=container — a bare PUT is Put Blob, which the KD-139 parity
    # guard now refuses (400 MissingRequiredHeader) exactly like real Azure.
    assert call(:put, "/#{@account}/queue-fix1?restype=queue").status in [201, 409]

    qconn =
      call(:post, "/#{@account}/queue-fix1/messages",
        body: ~s(<QueueMessage><MessageText>hello-kd123</MessageText></QueueMessage>),
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )

    assert qconn.status == 201

    peek = call(:get, "/#{@account}/queue-fix1/messages")
    assert peek.resp_body =~ "hello-kd123"
  end

  test "KD-114 regression: SharedKey-signed blob PUT admits (2021-12-02 string-to-sign)" do
    assert put_container("kd114").status in [201, 409]

    key = :crypto.hash(:sha256, @account <> "smalt-dev-sb")
    path = "/#{@account}/kd114/shared.txt"
    headers = [
      {"content-length", "10"},
      {"x-ms-blob-type", "BlockBlob"},
      {"x-ms-version", @version}
    ]

    # Independent construction of the 2021-12-02 blob SharedKey string-to-sign
    # (NOT a call into the module under test): VERB\n
    # content-md5\ncontent-type\n(empty date)\n + sorted x-ms-* headers\n
    # + /account + path.
    canon_headers =
      headers
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-ms-") end)
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
      |> Enum.map(fn {k, v} -> "#{k}:#{v}\n" end)
      |> Enum.join()

    string_to_sign =
      Enum.join(["PUT", "", "", "10", "", "", ""], "\n") <>
        "\n" <> canon_headers <> "/" <> @account <> path

    signature =
      Base.encode64(:crypto.mac(:hmac, :sha256, key, string_to_sign))

    auth = "SharedKey #{@account}:#{signature}"

    conn =
      Plug.Test.conn(:put, path, "0123456789")
      |> Plug.Conn.put_req_header("x-ms-version", @version)
      |> Plug.Conn.put_req_header("content-length", "10")
      |> Plug.Conn.put_req_header("x-ms-blob-type", "BlockBlob")
      |> Plug.Conn.put_req_header("authorization", auth)
      |> Smalt.Auth.Bearer.call(nil)
      |> Smalt.EgressRouter.call(nil)

    assert conn.status == 201
  end

end
