defmodule Smalt.AWS.SigV4Test do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.AWS.SigV4

  @creds %{"AKIDTEST" => "secretTEST"}

  defp signed(method, path, qs, body, secret \\ "secretTEST") do
    date = "20260101T000000Z"
    hs = [{"host", "localhost"}, {"x-amz-date", date}]
    auth = SigV4.sign(%{method: method, path: path, query: qs, headers: hs, body: body,
                        access_key_id: "AKIDTEST", secret: secret, region: "us-east-1", service: "s3", amz_date: date})
    conn(method, path <> if(qs == "", do: "", else: "?" <> qs), body)
    |> then(&%{&1 | req_headers: [{"host", "localhost"} | &1.req_headers]}) |> put_req_header("x-amz-date", date) |> put_req_header("authorization", auth)
  end

  test "round-trip verifies; wrong secret, tampered query and unknown key are refused" do
    assert {:ok, "AKIDTEST"} = SigV4.verify(signed("PUT", "/b/a b.txt", "x=1&a=2", "hi"), "hi", @creds)
    assert {:error, :mismatch} = SigV4.verify(signed("PUT", "/b/k", "", "hi", "wrong"), "hi", @creds)
    c = signed("GET", "/b/k", "a=1", "")
    assert {:error, :mismatch} = SigV4.verify(%{c | query_string: "a=2"}, "", @creds)
    assert {:error, :unknown_key} = SigV4.verify(signed("GET", "/b", "", ""), "", %{})
    assert {:error, :missing} = SigV4.verify(conn("GET", "/b"), "", @creds)
  end

  test "AWS documented GET-object vector signature" do
    # AWS S3 SigV4 docs example: GET /test.txt, Range header, examplebucket
    auth = SigV4.sign(%{method: "GET", path: "/test.txt", query: "",
      headers: [{"host", "examplebucket.s3.amazonaws.com"}, {"range", "bytes=0-9"},
                {"x-amz-content-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
                {"x-amz-date", "20130524T000000Z"}],
      payload_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      access_key_id: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      region: "us-east-1", service: "s3", amz_date: "20130524T000000Z"})
    assert auth =~ "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  end

  describe "SQS routes verify SigV4 (KD-SQ2)" do
    defp sqs_conn(secret) do
      date = "20260101T000000Z"
      body = "Action=ListQueues&Version=2012-11-05"
      hs = [{"host", "localhost"}, {"x-amz-date", date}]
      auth = SigV4.sign(%{method: "POST", path: "/", query: "", headers: hs, body: body,
                          access_key_id: "AKIDTEST", secret: secret, region: "us-east-1", service: "sqs", amz_date: date})
      conn("POST", "/", body)
      |> then(&%{&1 | req_headers: [{"host", "localhost"} | &1.req_headers]})
      |> put_req_header("x-amz-date", date)
      |> put_req_header("authorization", auth)
    end

    test "bad signature answers SignatureDoesNotMatch" do
      c = Smalt.Egress.Sqs.SqsRoutes.call(sqs_conn("wrong"), creds: @creds)
      assert c.status == 403
      assert c.halted
      assert c.resp_body =~ "SignatureDoesNotMatch"
    end

    test "good signature is admitted" do
      c = Smalt.Egress.Sqs.SqsRoutes.call(sqs_conn("secretTEST"), creds: @creds)
      refute c.resp_body =~ "SignatureDoesNotMatch"
      assert c.status == 200
    end
  end
end
