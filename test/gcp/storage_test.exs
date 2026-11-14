defmodule Smalt.GCP.StorageTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.GCP.Storage.{Router, Server}

  setup do
    name = :"gcs_#{System.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    {:ok, opts: Router.init(server: name, signing_key: "k3y")}
  end

  defp req(opts, method, path, body \\ "", headers \\ []) do
    conn = conn(method, path, body) |> Map.put(:host, "storage.googleapis.com")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, opts)
  end

  defp jbody(c), do: Jason.decode!(c.resp_body)

  defp mk(opts, b \\ "bkt") do
    c = req(opts, "POST", "/storage/v1/b?project=p", Jason.encode!(%{"name" => b}), [{"content-type", "application/json"}])
    assert c.status == 200
  end

  test "bucket lifecycle and typed errors", %{opts: o} do
    mk(o)
    assert req(o, "POST", "/storage/v1/b", Jason.encode!(%{"name" => "bkt"})).status == 409
    assert jbody(req(o, "GET", "/storage/v1/b/bkt"))["name"] == "bkt"
    c = req(o, "GET", "/storage/v1/b/nope")
    assert c.status == 404 and hd(jbody(c)["error"]["errors"])["reason"] == "notFound"
    assert req(o, "POST", "/storage/v1/b", Jason.encode!(%{"name" => "X"})).status == 400
    assert req(o, "DELETE", "/storage/v1/b/bkt").status == 204
  end

  test "media upload, get, alt=media, generations and preconditions", %{opts: o} do
    mk(o)
    c = req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=media&name=a%2Fb.txt&ifGenerationMatch=0", "hello", [{"content-type", "text/plain"}])
    assert c.status == 200
    g1 = jbody(c)["generation"]
    # exists now: ifGenerationMatch=0 must fail
    assert req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=media&name=a%2Fb.txt&ifGenerationMatch=0", "x").status == 412
    # correct generation overwrites
    c2 = req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=media&name=a%2Fb.txt&ifGenerationMatch=#{g1}", "world")
    assert c2.status == 200 and jbody(c2)["generation"] != g1
    m = req(o, "GET", "/storage/v1/b/bkt/o/a%2Fb.txt?alt=media")
    assert m.status == 200 and m.resp_body == "world"
    assert req(o, "GET", "/storage/v1/b/bkt/o/a%2Fb.txt?ifGenerationNotMatch=#{jbody(c2)["generation"]}").status == 412
    assert req(o, "DELETE", "/storage/v1/b/bkt/o/a%2Fb.txt?ifGenerationMatch=#{g1}").status == 412
    assert req(o, "DELETE", "/storage/v1/b/bkt/o/a%2Fb.txt").status == 204
    assert req(o, "GET", "/storage/v1/b/bkt/o/a%2Fb.txt").status == 404
  end

  test "resumable upload across chunks with status query", %{opts: o} do
    mk(o)
    s = req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=resumable&name=big", Jason.encode!(%{"contentType" => "x/y"}))
    assert s.status == 200
    [loc] = get_resp_header(s, "location")
    path = URI.parse(loc).path
    c1 = req(o, "PUT", path, "abcde", [{"content-range", "bytes 0-4/10"}])
    assert c1.status == 308 and get_resp_header(c1, "range") == ["bytes=0-4"]
    assert req(o, "PUT", path, "", [{"content-range", "bytes */10"}]).status == 308
    assert req(o, "PUT", path, "zzzzz", [{"content-range", "bytes 7-11/10"}]).status == 400
    c2 = req(o, "PUT", path, "fghij", [{"content-range", "bytes 5-9/10"}])
    assert c2.status == 200 and jbody(c2)["size"] == "10"
    assert req(o, "GET", "/bkt/big").resp_body == "abcdefghij"
  end

  test "multipart upload, list with delimiter, compose", %{opts: o} do
    mk(o)
    b = "BND"
    mp = "--BND\r\ncontent-type: application/json\r\n\r\n#{Jason.encode!(%{"name" => "d/one"})}\r\n--BND\r\ncontent-type: text/plain\r\n\r\nAAA\r\n--BND--\r\n"
    assert req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=multipart", mp, [{"content-type", "multipart/related; boundary=#{b}"}]).status == 200
    req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=media&name=d/two", "BBB")
    req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=media&name=top", "T")
    l = jbody(req(o, "GET", "/storage/v1/b/bkt/o?delimiter=/"))
    assert Enum.map(l["items"], & &1["name"]) == ["top"] and l["prefixes"] == ["d/"]
    body = Jason.encode!(%{"sourceObjects" => [%{"name" => "d/one"}, %{"name" => "d/two"}], "destination" => %{"contentType" => "text/plain"}})
    c = req(o, "POST", "/storage/v1/b/bkt/o/joined/compose", body)
    assert c.status == 200
    assert req(o, "GET", "/storage/v1/b/bkt/o/joined?alt=media").resp_body == "AAABBB"
    bad = Jason.encode!(%{"sourceObjects" => [%{"name" => "d/one"}, %{"name" => "missing"}]})
    assert req(o, "POST", "/storage/v1/b/bkt/o/j2/compose", bad).status == 404
  end

  test "XML API path-style, host-style, range, and signed URLs", %{opts: o} do
    mk(o)
    assert req(o, "PUT", "/bkt/x.bin", "0123456789").status == 200
    assert req(o, "PUT", "/bkt/x.bin", "n", [{"x-goog-if-generation-match", "0"}]).status == 412
    h = %{conn(:get, "/x.bin") | host: "bkt.storage.googleapis.com"}
    assert Router.call(h, o).resp_body == "0123456789"
    r = req(o, "GET", "/bkt/x.bin", "", [{"range", "bytes=2-4"}])
    assert r.status == 206 and r.resp_body == "234"
    assert req(o, "HEAD", "/bkt/x.bin").status == 200
    assert req(o, "GET", "/bkt/none").resp_body =~ "<Code>notFound</Code>"

    url = Smalt.GCP.Storage.sign_url("GET", "bkt", "x.bin", key: "k3y")
    assert req(o, "GET", url).status == 200
    assert req(o, "GET", String.replace(url, "/x.bin", "/y.bin")).status == 403
    old = Smalt.GCP.Storage.sign_url("GET", "bkt", "x.bin", key: "k3y", expires: 1, date: ~U[2020-01-01 00:00:00Z])
    assert req(o, "GET", old).status == 403
  end

  test "ifGenerationMatch is atomic under concurrent writers", %{opts: o} do
    mk(o)
    results =
      1..20
      |> Task.async_stream(fn i -> req(o, "POST", "/upload/storage/v1/b/bkt/o?uploadType=media&name=race&ifGenerationMatch=0", "w#{i}").status end)
      |> Enum.map(fn {:ok, s} -> s end)
    assert Enum.count(results, &(&1 == 200)) == 1
    assert Enum.count(results, &(&1 == 412)) == 19
  end
end
