defmodule Smalt.Integration.BlobParityTest do
  # B-KD lane (v26.10.20): real-router, real-ETS parity witnesses for the
  # KD-135/137/139 blob parity fixes. No mocks — assertions on wire status,
  # headers, and bytes.
  use ExUnit.Case, async: false

  @account "acct-bkd"

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
      Plug.Test.conn(method, path, opts[:body])
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  # B-XML lane's StorageError XML renderer is live on the blob face; the
  # code may arrive as JSON envelope or XML <Code>.
  defp error_code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ ->
        case Regex.run(~r/<Code>([^<]+)<\/Code>/, conn.resp_body) do
          [_, code] -> code
          _ -> nil
        end
    end
  end

  defp put_container(container, headers \\ []) do
    call(:put, "/#{@account}/#{container}?restype=container", headers: headers)
  end

  defp put_blob(container, blob, headers) do
    call(:put, "/#{@account}/#{container}/#{blob}",
      body: "0123456789",
      headers: headers
    )
  end

  # ---- KD-139: PUT blob without x-ms-blob-type -> 400 MissingRequiredHeader

  test "KD-139: headerless blob PUT answers 400 MissingRequiredHeader" do
    assert put_container("kd139").status in [201, 409]

    conn = put_blob("kd139", "nohint.txt", [])

    assert conn.status == 400
    assert error_code(conn) == "MissingRequiredHeader"
    assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == ["MissingRequiredHeader"]
  end

  test "KD-139: blank blob-type is refused, present blob-type is admitted" do
    assert put_container("kd139").status in [201, 409]
    assert call(:put, "/#{@account}/kd139/blank.txt", body: "x", headers: [{"x-ms-blob-type", " "}]).status == 400

    conn = put_blob("kd139", "typed.txt", [{"x-ms-blob-type", "BlockBlob"}])

    assert conn.status == 201
  end

  # ---- KD-137: 416 arm carries x-ms-error-code: InvalidRange

  test "KD-137: range past EOF answers 416 with x-ms-error-code InvalidRange" do
    assert put_container("kd137").status in [201, 409]
    assert put_blob("kd137", "ten.txt", [{"x-ms-blob-type", "BlockBlob"}]).status == 201

    conn =
      call(:get, "/#{@account}/kd137/ten.txt", headers: [{"x-ms-range", "bytes=1000-2000"}])

    assert conn.status == 416
    assert Plug.Conn.get_resp_header(conn, "x-ms-error-code") == ["InvalidRange"]
    assert Plug.Conn.get_resp_header(conn, "content-range") == ["bytes */10"]
  end

  # ---- KD-135: default container is writable; immutability is opt-in

  test "KD-135: delete on a default (no immutable header) container answers 202" do
    assert put_container("kd135-writable").status in [201, 409]
    assert put_blob("kd135-writable", "del.txt", [{"x-ms-blob-type", "BlockBlob"}]).status == 201

    conn = call(:delete, "/#{@account}/kd135-writable/del.txt")

    assert conn.status == 202
  end

  test "KD-135: explicitly immutable container still enforces WORM delete refusal" do
    assert put_container("kd135-immutable", [{"x-ms-immutable-policy", "true"}]).status in [201, 409]
    assert put_blob("kd135-immutable", "keep.txt", [{"x-ms-blob-type", "BlockBlob"}]).status == 201

    conn = call(:delete, "/#{@account}/kd135-immutable/keep.txt")

    assert conn.status == 409
    assert error_code(conn) == "ContainerLocked"
  end
end
