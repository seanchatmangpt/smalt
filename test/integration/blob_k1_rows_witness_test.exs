defmodule Smalt.Integration.BlobK1RowsWitnessTest do
  # K1 divergence-finish lane: plug-conn witness court for KD-67, KD-66, KD-02.
  # Real router, real BlobStorage ETS, no mocks — assertions on wire bytes.
  use ExUnit.Case, async: false

  @account "acct-k1"

  defp call(method, path, opts \\ []) do
    body = opts[:body]
    headers = opts[:headers] || []

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp put_container(container) do
    conn = call(:put, "/#{@account}/#{container}?restype=container")

    unless conn.status == 201, do: throw({:create_failed, conn.status, conn.resp_body})

    conn
  end

  defp put_blob(container, name, content, opts \\ []) do
    # FIX-1 unblock (compile-freeze SLA, disclosed by B-KD): stamp
    # x-ms-blob-type — the KD-139 parity guard now refuses headerless Put
    # Blob with 400 MissingRequiredHeader, so the fixtures must name the
    # blob type like every real Azure SDK client does.
    headers = [{"x-ms-blob-type", "BlockBlob"}] ++ (opts[:headers] || [])

    call(:put, "/#{@account}/#{container}/#{name}", body: content, headers: headers)
  end

  describe "KD-67 x-ms-version grammar validation" do
    test "garbage version 400s at the admission guard" do
      conn =
        Plug.Test.conn(:put, "/#{@account}/k1ver?restype=container", nil)
        |> Plug.Conn.put_req_header("x-ms-version", "garbage-version")

      conn = Smalt.EgressRouter.call(conn, [])

      assert conn.status == 400
      assert conn.resp_body =~ "MissingXMsVersion"

      # duplicate headers (valid + junk) stay refused (R136 class)
      conn2 =
        Plug.Test.conn(:put, "/#{@account}/k1ver?restype=container", nil)
        |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
        |> Plug.Conn.put_req_header("x-ms-version", "junk")

      conn2 = Smalt.EgressRouter.call(conn2, [])
      assert conn2.status == 400
    end

    test "valid versions still admitted (2026-01-01, 2023-11-03)" do
      for v <- ["2023-11-03", "2026-01-01"] do
        conn =
          Plug.Test.conn(:put, "/#{@account}/k1ver-ok-#{v}?restype=container", nil)
          |> Plug.Conn.put_req_header("x-ms-version", v)

        conn = Smalt.EgressRouter.call(conn, [])
        assert conn.status == 201
      end
    end
  end

  describe "KD-66 ranged GET Content-MD5" do
    test "x-ms-range-get-content-md5 true answers the range digest" do
      put_container("k1md5c")
      put_blob("k1md5c", "r1.txt", "hello range")

      conn =
        call(:get, "/#{@account}/k1md5c/r1.txt",
          headers: [
            {"x-ms-range", "bytes=0-4"},
            {"x-ms-range-get-content-md5", "true"}
          ]
        )

      assert conn.status == 206

      expected = :crypto.hash(:md5, "hello") |> Base.encode64()
      assert Plug.Conn.get_resp_header(conn, "content-md5") == [expected]
    end

    test "without the request header the wire is unchanged (no content-md5)" do
      put_container("k1md5d")
      put_blob("k1md5d", "r2.txt", "hello range")

      conn =
        call(:get, "/#{@account}/k1md5d/r2.txt", headers: [{"x-ms-range", "bytes=0-4"}])

      assert conn.status == 206
      assert Plug.Conn.get_resp_header(conn, "content-md5") == []
    end
  end

  describe "KD-02 list blobs BlobProperties + Prefix echo" do
    test "properties carry Content-Type, LeaseStatus, LeaseState; RFC-1123 dates" do
      put_container("k1listc")
      put_blob("k1listc", "b1.txt", "abc", headers: [{"content-type", "text/plain"}])

      conn = call(:get, "/#{@account}/k1listc?restype=container&comp=list")

      assert conn.status == 200

      assert conn.resp_body =~ "<Content-Type>text/plain</Content-Type>"
      assert conn.resp_body =~ "<LeaseStatus>unlocked</LeaseStatus>"
      assert conn.resp_body =~ "<LeaseState>available</LeaseState>"
      assert conn.resp_body =~ "<BlobType>BlockBlob</BlobType>"
      assert conn.resp_body =~ ~r|<Last-Modified>[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT</Last-Modified>|
    end

    test "Prefix echoes the requested prefix, empty when absent" do
      put_container("k1pfx")
      put_blob("k1pfx", "dir/a.txt", "x")
      put_blob("k1pfx", "e.txt", "x")

      conn = call(:get, "/#{@account}/k1pfx?restype=container&comp=list")
      assert conn.resp_body =~ "<Prefix></Prefix>"

      conn2 = call(:get, "/#{@account}/k1pfx?restype=container&comp=list&prefix=dir/")
      assert conn2.resp_body =~ "<Prefix>dir/</Prefix>"
    end
  end
end
