defmodule Smalt.Integration.BlobXmlErrorTest do
  # B-XML court: blob-face errors render the Azure Storage XML error envelope
  # (closes GAP(blob-error-envelope-json)), scoped to the blob face only.
  # Real router, real BlobStorage ETS, no mocks — assertions on wire bytes.
  use ExUnit.Case, async: false

  @account "acct-bxml"

  defp call(method, path, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [])
      |> Kernel.++(if opts[:no_version], do: [], else: [{"x-ms-version", "2023-11-03"}])

    method
    |> Plug.Test.conn(path, opts[:body])
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)
    |> Smalt.EgressRouter.call([])
  end

  defp put_container(name) do
    conn = call(:put, "/#{@account}/#{name}?restype=container")
    assert conn.status == 201, "container PUT -> " <> inspect(IO.iodata_to_binary(conn.resp_body))
    conn
  end

  defp put_blob(container, name, body \\ "bxml-payload") do
    call(:put, "/#{@account}/#{container}/#{name}",
      headers: [{"x-ms-blob-type", "BlockBlob"}],
      body: body
    )
  end

  defp assert_xml_error(conn, status, code) do
    assert conn.status == status

    body = IO.iodata_to_binary(conn.resp_body)
    assert String.starts_with?(body, ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>))
    assert body =~ "<Code>#{code}</Code>"
    assert String.ends_with?(body, "</Message></Error>")

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]
    assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == [code]

    assert [req_id] = Plug.Conn.get_resp_header(conn, "x-ms-request-id")

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             req_id
           )

    assert Plug.Conn.get_resp_header(conn, "x-ms-version") == ["2021-12-02"]
  end

  describe "blob-face XML error envelope (GAP(blob-error-envelope-json))" do
    @tag :bxml
    test "BlobNotFound 404 is XML with the full error header set" do
      assert put_container("c1x").status == 201
      assert_xml_error(call(:get, "/#{@account}/c1x/no-such-blob"), 404, "BlobNotFound")
    end

    @tag :bxml
    test "ContainerNotFound 404 is XML (blob PUT into a missing container)" do
      assert_xml_error(
        call(:put, "/#{@account}/no-such-container/blob.txt",
          headers: [{"x-ms-blob-type", "BlockBlob"}],
          body: "x"
        ),
        404,
        "ContainerNotFound"
      )
    end

    @tag :bxml
    test "ContainerAlreadyExists 409 is XML" do
      assert call(:put, "/#{@account}/dupc?restype=container").status == 201
      assert_xml_error(call(:put, "/#{@account}/dupc?restype=container"), 409, "ContainerAlreadyExists")
    end

    @tag :bxml
    test "InvalidQueryParameterValue 400 is XML (unhandled comp)" do
      assert put_container("c2x").status == 201

      assert_xml_error(
        call(:get, "/#{@account}/c2x/blk?comp=absolutely-not-a-comp"),
        400,
        "InvalidQueryParameterValue"
      )
    end

    @tag :bxml
    test "MissingXMsVersion 400 is XML" do
      assert_xml_error(
        call(:get, "/#{@account}/c1/blk", no_version: true),
        400,
        "MissingXMsVersion"
      )
    end

    @tag :bxml
    test "InvalidRange 416 is XML with x-ms-error-code: InvalidRange" do
      assert put_container("c3x").status == 201
      assert put_blob("c3x", "r").status == 201

      assert_xml_error(
        call(:get, "/#{@account}/c3x/r", headers: [{"x-ms-range", "bytes=99999999-"}]),
        416,
        "InvalidRange"
      )
    end
  end

  describe "scope regression — non-blob faces stay JSON" do
    @tag :bxml
    test "blob_error WITHOUT the blob-face stamp renders JSON (byte-identical legacy)" do
      conn =
        Plug.Test.conn(:get, "/whatever")
        |> Smalt.EgressRouter.blob_error(404, Smalt.EgressRouter.not_found_error("BlobNotFound"))

      assert conn.status == 404
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert %{"error" => %{"code" => "BlobNotFound"}} = Jason.decode!(conn.resp_body)
      assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == ["BlobNotFound"]
      # Non-blob faces keep the F5 error headers but never the XML envelope.
      assert Plug.Conn.get_resp_header(conn, "x-ms-version") == ["2021-12-02"]
    end

    @tag :bxml
    test "untyped blob-face body keeps the JSON fallback renderer" do
      conn =
        Plug.Test.conn(:get, "/whatever")
        |> Plug.Conn.put_private(:smalt_blob_face, true)
        |> Smalt.EgressRouter.blob_error(500, %{"error" => "untyped-failure"})

      assert conn.status == 500
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert Jason.decode!(conn.resp_body) == %{"error" => "untyped-failure"}
    end

    @tag :bxml
    test "blob face success path unchanged (container PUT 201 empty, quoted ETag)" do
      conn = put_container("okx")

      assert conn.status == 201
      assert conn.resp_body == ""
      assert Plug.Conn.get_resp_header(conn, "etag") |> hd() =~ ~s(")
    end
  end
end
