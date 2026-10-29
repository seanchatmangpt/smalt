defmodule Smalt.Integration.BlobQuotaHeadersTest do
  # T31RQ (v26.10.20) — resource-quota/encryption telemetry headers, census
  # witness: real Azure Storage answers every write op (Put Blob, Put Block,
  # Put Block List, Set Blob Metadata) with
  # `x-ms-request-server-encrypted: true` (Azure Storage REST reference,
  # "This header is returned ... to confirm the contents of the request are
  # successfully encrypted"). Before this lane, smalt emitted it nowhere.
  # Chicago court: real router, real store, assertions on wire headers.
  use ExUnit.Case, async: false

  @account "acct-t31rq"

  defp call(method, path, opts \\ []) do
    headers = opts[:headers] || []
    body = opts[:body]

    headers =
      if body do
        [{"content-length", body |> byte_size() |> Integer.to_string()} | headers]
      else
        headers
      end

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("content-length", "0")
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp hdr(conn, name), do: Enum.find_value(conn.resp_headers, fn {k, v} -> k == name && v end)

  defp put_container(container),
    do: call(:put, "/#{@account}/#{container}?restype=container")

  test "Put Blob answers 201 with x-ms-request-server-encrypted: true" do
    assert put_container("cn1").status in [201, 409]

    conn =
      call(:put, "/#{@account}/cn1/putblob.bin",
        body: "0123456789",
        headers: [{"x-ms-blob-type", "BlockBlob"}]
      )

    assert conn.status == 201
    assert hdr(conn, "x-ms-request-server-encrypted") == "true"
  end

  test "Put Block / Put Block List answer with x-ms-request-server-encrypted: true" do
    assert put_container("cn2").status in [201, 409]

    block_id = Base.encode64("b1")

    conn =
      call(:put, "/#{@account}/cn2/staged.bin?comp=block&blockid=#{block_id}", body: "aaaa")

    assert conn.status == 201
    assert hdr(conn, "x-ms-request-server-encrypted") == "true"

    xml = """
    <BlockList><Latest>#{block_id}</Latest></BlockList>
    """

    conn2 =
      call(:put, "/#{@account}/cn2/staged.bin?comp=blocklist", body: xml)

    assert conn2.status == 201
    assert hdr(conn2, "x-ms-request-server-encrypted") == "true"
  end

  test "Set Blob Metadata answers 200 with x-ms-request-server-encrypted: true" do
    assert put_container("cn3").status in [201, 409]

    assert call(:put, "/#{@account}/cn3/meta.bin",
             body: "x",
             headers: [{"x-ms-blob-type", "BlockBlob"}]
           ).status == 201

    conn = call(:put, "/#{@account}/cn3/meta.bin?comp=metadata", headers: [{"x-ms-meta-k", "v"}])
    assert conn.status == 200
    assert hdr(conn, "x-ms-request-server-encrypted") == "true"
  end
end
