defmodule Smalt.Integration.Bk132CorpusTriageTest do
  # BK-132 (v26.10.22) corpus-triage court leg: real router + real ETS, no
  # mocks. Covers the FIXED-NOW dispositions (set-tier direct arm, sync copy
  # via x-ms-copy-source, cors GET echo) and the two GAP falsifiers.
  use ExUnit.Case, async: false

  @account "acct-bk132"

  defp call(method, path, opts \\ []) do
    headers = opts[:headers] || []

    headers =
      if opts[:body] do
        [{"content-length", Integer.to_string(byte_size(opts[:body]))} | headers]
      else
        headers
      end

    conn =
      Plug.Test.conn(method, path, opts[:body])
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp put_container_ok(name, headers \\ []) do
    case call(:put, "/#{@account}/#{name}?restype=container", headers: headers) do
      %Plug.Conn{status: s} = c when s in [201, 409] -> c
      c -> flunk("container create failed: #{c.status} #{c.resp_body}")
    end
  end

  defp put_blob(container, blob, body, headers \\ []) do
    call(:put, "/#{@account}/#{container}/#{blob}",
      body: body,
      headers: [{"x-ms-blob-type", "BlockBlob"} | headers]
    )
  end

  test "set-tier: PUT ?comp=tier stores the tier; GET echoes x-ms-access-tier" do
    put_container_ok("tier")
    put_blob("tier", "b1", "tier-src")

    conn = call(:put, "/#{@account}/tier/b1?comp=tier", headers: [{"x-ms-access-tier", "Cool"}])
    assert conn.status == 200, conn.resp_body

    get = call(:get, "/#{@account}/tier/b1")
    assert get.status == 200
    assert {"x-ms-access-tier", "Cool"} in get.resp_headers
  end

  test "sync copy: PUT with x-ms-copy-source copies content; 202 + copy headers" do
    put_container_ok("copy")
    put_blob("copy", "src", "COPYBODY123456")

    conn =
      call(:put, "/#{@account}/copy/dst",
        body: "",
        headers: [{"x-ms-copy-source", "/acct-bk132/copy/src"}]
      )

    assert conn.status == 202, conn.resp_body
    assert Enum.any?(conn.resp_headers, fn {k, v} -> k == "x-ms-copy-id" and v != "" end)

    get = call(:get, "/#{@account}/copy/dst")
    assert get.status == 200
    assert get.resp_body == "COPYBODY123456"

    assert Enum.any?(get.resp_headers, fn {k, _} -> k == "x-ms-copy-status" end)
  end

  test "sync copy: missing source blob answers typed 404 BlobNotFound" do
    put_container_ok("copy")

    conn =
      call(:put, "/#{@account}/copy/no-dst",
        body: "",
        headers: [{"x-ms-copy-source", "/acct-bk132/copy/does-not-exist"}]
      )

    assert conn.status == 404
    assert Regex.run(~r/<Code>BlobNotFound<\/Code>/, conn.resp_body)
  end

  test "cors: PUT service properties stores rules; GET echoes the Cors block" do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <StorageServiceProperties>
      <Cors><CorsRule>
        <AllowedOrigins>https://example.com</AllowedOrigins>
        <AllowedMethods>GET,PUT</AllowedMethods>
        <AllowedHeaders>*</AllowedHeaders>
        <ExposedHeaders>x-ms-request-id</ExposedHeaders>
        <MaxAgeInSeconds>1800</MaxAgeInSeconds>
      </CorsRule></Cors>
    </StorageServiceProperties>
    """

    put_conn = call(:put, "/#{@account}?restype=service&comp=properties", body: body)
    assert put_conn.status == 202, put_conn.resp_body

    get = call(:get, "/#{@account}?restype=service&comp=properties")
    assert get.status == 200

    assert Regex.run(~r/<AllowedOrigins>https:\/\/example\.com<\/AllowedOrigins>/, get.resp_body),
           get.resp_body
  end

  test "GAP(az-blob-restore): PUT ?restype=account&comp=undeleteset is typed-denied" do
    conn = call(:put, "/#{@account}?restype=account&comp=undeleteset", body: "")
    assert conn.status in [400, 404, 405]
  end

  test "GAP(az-blob-incremental-copy): PUT ?comp=incrementalcopy is typed-denied" do
    put_container_ok("incr")

    conn = call(:put, "/#{@account}/incr/b?comp=incrementalcopy", body: "")
    assert conn.status == 400
  end
end
