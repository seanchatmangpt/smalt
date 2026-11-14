defmodule Smalt.AWS.S3Test do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.AWS.{S3, SigV4}
  alias Smalt.AWS.S3.Router

  @creds %{"AKIDTEST" => "secretTEST"}

  setup do
    name = :"s3_#{System.unique_integer([:positive])}"
    start_supervised!({S3.Server, name: name})
    {:ok, o: Router.init(server: name, creds: @creds, min_part: 5)}
  end

  defp req(o, method, path, qs \\ "", body \\ "", extra \\ []) do
    date = "20260101T000000Z"
    hs = [{"host", "localhost"}, {"x-amz-date", date}] ++ extra
    auth = SigV4.sign(%{method: method, path: path, query: qs, headers: hs, body: body,
                        access_key_id: "AKIDTEST", secret: "secretTEST", region: "us-east-1", service: "s3", amz_date: date})
    c = conn(method, path <> if(qs == "", do: "", else: "?" <> qs), body)
    c = Enum.reduce(hs, c, fn {k, v}, c -> %{c | req_headers: c.req_headers ++ [{k, v}]} end)
    Router.call(put_req_header(c, "authorization", auth), o)
  end

  test "unsigned and badly signed requests are refused; non-AWS passes through", %{o: o} do
    assert Router.call(conn("GET", "/"), o).halted == false
    c = req(o, "PUT", "/bkt") |> then(fn _ -> conn("GET", "/") |> put_req_header("authorization", "AWS4-HMAC-SHA256 Credential=AKIDTEST/20260101/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=00") |> put_req_header("x-amz-date", "20260101T000000Z") |> Router.call(o) end)
    assert c.status == 403 and c.resp_body =~ "SignatureDoesNotMatch"
  end

  test "bucket and object lifecycle with typed errors", %{o: o} do
    assert req(o, "PUT", "/bkt").status == 200
    assert req(o, "PUT", "/bkt").status == 409
    assert req(o, "PUT", "/Bad_Name").status == 400
    c = req(o, "PUT", "/bkt/dir/a b.txt", "", "hello")
    assert c.status == 200
    [etag] = get_resp_header(c, "etag")
    g = req(o, "GET", "/bkt/dir/a b.txt")
    assert g.status == 200 and g.resp_body == "hello" and get_resp_header(g, "etag") == [etag]
    assert req(o, "HEAD", "/bkt/dir/a b.txt").status == 200
    assert req(o, "GET", "/bkt/nope").resp_body =~ "NoSuchKey"
    assert req(o, "GET", "/nobkt/x").resp_body =~ "NoSuchBucket"
    assert req(o, "DELETE", "/bkt").resp_body =~ "BucketNotEmpty"
    assert req(o, "DELETE", "/bkt/dir/a b.txt").status == 204
    assert req(o, "DELETE", "/bkt").status == 204
    assert req(o, "GET", "/").resp_body =~ "<Buckets></Buckets>"
  end

  test "If-Match / If-None-Match preconditions", %{o: o} do
    req(o, "PUT", "/bkt")
    c = req(o, "PUT", "/bkt/k", "", "v1", [{"if-none-match", "*"}])
    assert c.status == 200
    [e1] = get_resp_header(c, "etag")
    assert req(o, "PUT", "/bkt/k", "", "v2", [{"if-none-match", "*"}]).status == 412
    assert req(o, "PUT", "/bkt/k", "", "v2", [{"if-match", "\"wrong\""}]).status == 412
    assert req(o, "PUT", "/bkt/k", "", "v2", [{"if-match", e1}]).status == 200
    assert req(o, "GET", "/bkt/k").resp_body == "v2"
    assert req(o, "DELETE", "/bkt/k", "", "", [{"if-match", e1}]).status == 412
    [e2] = req(o, "GET", "/bkt/k") |> get_resp_header("etag")
    assert req(o, "GET", "/bkt/k", "", "", [{"if-none-match", e2}]).status == 304
  end

  test "ListObjectsV2 prefix, delimiter, pagination", %{o: o} do
    req(o, "PUT", "/bkt")
    for k <- ["a/1", "a/2", "b/1", "c"], do: req(o, "PUT", "/bkt/" <> k, "", k)
    r = req(o, "GET", "/bkt", "list-type=2&delimiter=%2F")
    assert r.resp_body =~ "<Prefix>a/</Prefix>" and r.resp_body =~ "<Prefix>b/</Prefix>" and r.resp_body =~ "<Key>c</Key>"
    r = req(o, "GET", "/bkt", "list-type=2&prefix=a%2F")
    assert r.resp_body =~ "<KeyCount>2</KeyCount>"
    p1 = req(o, "GET", "/bkt", "list-type=2&max-keys=2")
    assert p1.resp_body =~ "<IsTruncated>true</IsTruncated>" and p1.resp_body =~ "<NextContinuationToken>a/2<"
    p2 = req(o, "GET", "/bkt", "list-type=2&continuation-token=a%2F2")
    assert p2.resp_body =~ "<KeyCount>2</KeyCount>" and p2.resp_body =~ "<IsTruncated>false"
  end

  test "multipart: init, parts, complete (composite etag), abort, invalid part", %{o: o} do
    req(o, "PUT", "/bkt")
    init = req(o, "POST", "/bkt/big", "uploads")
    [_, id] = Regex.run(~r/<UploadId>(.*?)<\/UploadId>/, init.resp_body)
    p1 = req(o, "PUT", "/bkt/big", "partNumber=1&uploadId=#{id}", "AAAAAA")
    p2 = req(o, "PUT", "/bkt/big", "partNumber=2&uploadId=#{id}", "BB")
    [e1] = get_resp_header(p1, "etag")
    [e2] = get_resp_header(p2, "etag")
    part = fn n, e -> "<Part><PartNumber>#{n}</PartNumber><ETag>#{String.replace(e, "\"", "&quot;")}</ETag></Part>" end
    bad = req(o, "POST", "/bkt/big", "uploadId=#{id}", "<CompleteMultipartUpload>#{part.(1, "\"zz\"")}</CompleteMultipartUpload>")
    assert bad.resp_body =~ "InvalidPart"
    ok = req(o, "POST", "/bkt/big", "uploadId=#{id}", "<CompleteMultipartUpload>#{part.(1, e1)}#{part.(2, e2)}</CompleteMultipartUpload>")
    assert ok.status == 200 and ok.resp_body =~ "-2&quot;" or ok.resp_body =~ "-2\""
    assert req(o, "GET", "/bkt/big").resp_body == "AAAAAABB"
    assert req(o, "POST", "/bkt/big", "uploadId=#{id}", "<CompleteMultipartUpload></CompleteMultipartUpload>").resp_body =~ "NoSuchUpload"
    id2 = Regex.run(~r/<UploadId>(.*?)</, req(o, "POST", "/bkt/x", "uploads").resp_body) |> List.last()
    assert req(o, "DELETE", "/bkt/x", "uploadId=#{id2}").status == 204
    assert req(o, "PUT", "/bkt/x", "partNumber=1&uploadId=#{id2}", "z").resp_body =~ "NoSuchUpload"
  end
end
