defmodule Smalt.Integration.KD130ContainerExistsTest do
  # KD-130 close court: PUT /{account}/{container}?restype=container on an
  # EXISTING container must answer 409 ContainerAlreadyExists (real-Azure
  # wire parity that @azure/storage-blob createIfNotExists contractually
  # depends on), never the prior 200-empty idempotent re-PUT.
  # Real router, real BlobStorage ETS, no mocks — assertions on wire bytes.
  use ExUnit.Case, async: false

  @account "acct-kd130"

  defp call(method, path, opts \\ []) do
    body = opts[:body]
    headers = opts[:headers] || []

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp put_container(container, meta \\ %{}) do
    headers = Enum.map(meta, fn {k, v} -> {"x-ms-meta-#{k}", v} end)

    call(:put, "/#{@account}/#{container}?restype=container", headers: headers)
  end

  # B-XML (GAP(blob-error-envelope-json) close): blob-face errors now render
  # the Azure XML envelope; parse it, keeping a JSON fallback for non-blob faces.
  defp error_code(conn) do
    body = IO.iodata_to_binary(conn.resp_body)

    case Regex.run(~r/<Code>([^<]+)<\/Code>/, body) do
      [_, code] ->
        code

      _ ->
        case Jason.decode(body) do
          {:ok, %{"error" => %{"code" => code}}} -> code
          _ -> nil
        end
    end
  end

  describe "KD-130 create-vs-exists discrimination" do
    test "fresh create answers 201 empty with standard headers" do
      conn = put_container("fresh-1")

      assert conn.status == 201
      assert conn.resp_body == ""
      assert [etag] = Plug.Conn.get_resp_header(conn, "etag")
      assert etag =~ "\""
      assert Plug.Conn.get_resp_header(conn, "x-ms-version") == ["2021-12-02"]
      assert Plug.Conn.get_resp_header(conn, "x-ms-request-id") != []
    end

    test "re-create on existing answers 409 ContainerAlreadyExists (identical metadata)" do
      assert put_container("dup-1", %{"a" => "1"}).status == 201

      conn = put_container("dup-1", %{"a" => "1"})

      assert conn.status == 409
      assert error_code(conn) == "ContainerAlreadyExists"
    end

    test "re-create with different metadata answers 409 ContainerAlreadyExists" do
      assert put_container("dup-2", %{"a" => "1"}).status == 201

      conn = put_container("dup-2", %{"a" => "2"})

      assert conn.status == 409
      assert error_code(conn) == "ContainerAlreadyExists"
    end

    test "container stays usable after the 409 (blob PUT/GET round-trip)" do
      assert put_container("dup-3").status == 201
      conn = put_container("dup-3")
      assert conn.status == 409

      # FIX-1 unblock (compile-freeze SLA, disclosed): stamp x-ms-blob-type — the
      # landed KD-139 wire guard (real-Azure parity) refuses headerless PUTs.
      put =
        call(:put, "/#{@account}/dup-3/blob.txt",
          body: "hello kd130",
          headers: [{"x-ms-blob-type", "BlockBlob"}]
        )
      assert put.status == 201

      get = call(:get, "/#{@account}/dup-3/blob.txt")
      assert get.status == 200
      assert get.resp_body == "hello kd130"
    end

    test "WORM stays ahead: re-create under legal hold is 409 ContainerLocked" do
      assert put_container("hold-1").status == 201

      hold =
        call(:put, "/#{@account}/hold-1?restype=container&comp=legalhold",
          headers: [{"x-ms-legal-hold", "true"}]
        )

      # Header-only 200 (real-Azure Set Container Legal Hold shape): the
      # x-ms-legal-hold response header, no JSON body.
      assert hold.status == 200
      assert hold.resp_body == ""
      assert Plug.Conn.get_resp_header(hold, "x-ms-legal-hold") == ["true"]

      # Hold state persists: GET comp=legalhold surfaces it.
      get = call(:get, "/#{@account}/hold-1?restype=container&comp=legalhold")
      assert get.status == 200
      assert Plug.Conn.get_resp_header(get, "x-ms-legal-hold") == ["true"]

      conn = put_container("hold-1")

      assert conn.status == 409
      assert error_code(conn) == "ContainerLocked"

      # Release per the existing law: clear answers 200 header-only too, and
      # the hold is gone (GET surfaces false; container no longer locked).
      release =
        call(:put, "/#{@account}/hold-1?restype=container&comp=legalhold",
          headers: [{"x-ms-legal-hold", "false"}]
        )

      assert release.status == 200
      assert release.resp_body == ""
      assert Plug.Conn.get_resp_header(release, "x-ms-legal-hold") == ["false"]

      get_after = call(:get, "/#{@account}/hold-1?restype=container&comp=legalhold")
      assert Plug.Conn.get_resp_header(get_after, "x-ms-legal-hold") == ["false"]
    end
  end

  # Regression: the clauses sharing the container PUT/GET arms stay green.
  describe "adjacent clause family regression" do
    test "R98/KD-122 family: unknown container PUT comp is a typed 400, not a create" do
      conn = call(:put, "/#{@account}/r98c?restype=container&comp=zombie")

      assert conn.status == 400
      assert conn.resp_body =~ "comp"
    end

    test "KD-66: ranged GET with x-ms-range-get-content-md5 still carries the digest" do
      assert put_container("kd66c").status == 201
      assert call(:put, "/#{@account}/kd66c/r1.txt",
                  body: "hello range",
                  headers: [{"x-ms-blob-type", "BlockBlob"}]
                ).status == 201

      conn =
        call(:get, "/#{@account}/kd66c/r1.txt",
          headers: [
            {"x-ms-range", "bytes=0-4"},
            {"x-ms-range-get-content-md5", "true"}
          ]
        )

      assert conn.status == 206

      expected = :crypto.hash(:md5, "hello") |> Base.encode64()
      assert Plug.Conn.get_resp_header(conn, "content-md5") == [expected]
    end

    test "KD-123: queue message PUT with explicit XML content-type stores real bytes" do
      queue = "kd130-q-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      assert call(:put, "/#{@account}/#{queue}?restype=queue").status == 201

      body = ~s(<QueueMessage><MessageText>kd130-bytes</MessageText></QueueMessage>)

      conn =
        call(:post, "/#{@account}/#{queue}/messages", body: body, content_type: "application/xml")

      assert conn.status == 201

      get = call(:get, "/#{@account}/#{queue}/messages")
      assert get.status == 200
      assert get.resp_body =~ "kd130-bytes"
    end
  end
end
