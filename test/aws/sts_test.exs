defmodule Smalt.AWS.STSTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.AWS.{DynamoDB.Router, SigV4, STS}

  @creds %{"AKIDTEST" => "secretTEST"}
  @date "20260101T000000Z"

  setup do: {:ok, o: Router.init(creds: @creds, identities: %{"AKIDTEST" => %{account: "123456789012", arn: "arn:aws:iam::123456789012:user/tester", user_id: "AIDATESTER"}})}

  defp signed(o, akid, secret, svc, headers, body) do
    hs = [{"host", "localhost"}, {"x-amz-date", @date}] ++ headers
    auth = SigV4.sign(%{method: "POST", path: "/", query: "", headers: hs, body: body, access_key_id: akid, secret: secret, region: "us-east-1", service: svc, amz_date: @date})
    c = Enum.reduce(hs, conn("POST", "/", body), fn {k, v}, c -> %{c | req_headers: c.req_headers ++ [{k, v}]} end)
    Router.call(put_req_header(c, "authorization", auth), o)
  end

  defp sts(o, params, akid \\ "AKIDTEST", secret \\ "secretTEST") do
    signed(o, akid, secret, "sts", [{"content-type", "application/x-www-form-urlencoded"}], URI.encode_query(params))
  end

  test "GetCallerIdentity returns the configured identity as XML", %{o: o} do
    c = sts(o, %{"Action" => "GetCallerIdentity", "Version" => "2011-06-15"})
    assert c.status == 200
    assert c.resp_body =~ "<Arn>arn:aws:iam::123456789012:user/tester</Arn>"
    assert c.resp_body =~ "<Account>123456789012</Account>"
  end

  test "bad signature is refused with XML error", %{o: o} do
    c = sts(o, %{"Action" => "GetCallerIdentity"}, "AKIDTEST", "wrong")
    assert c.status == 403 and c.resp_body =~ "SignatureDoesNotMatch"
  end

  test "AssumeRole credentials sign real DynamoDB and KMS requests; identity becomes assumed-role", %{o: o} do
    c = sts(o, %{"Action" => "AssumeRole", "RoleArn" => "arn:aws:iam::123456789012:role/Dev", "RoleSessionName" => "sess1"})
    assert c.status == 200
    [_, akid] = Regex.run(~r/<AccessKeyId>(ASIA[A-Z2-7]{16})<\/AccessKeyId>/, c.resp_body)
    [_, secret] = Regex.run(~r/<SecretAccessKey>([A-Za-z0-9]{40})<\/SecretAccessKey>/, c.resp_body)
    assert c.resp_body =~ "<SessionToken>" and c.resp_body =~ "<Expiration>"

    who = sts(o, %{"Action" => "GetCallerIdentity"}, akid, secret)
    assert who.resp_body =~ "arn:aws:sts::123456789012:assumed-role/Dev/sess1"

    t = "sts_t_#{System.unique_integer([:positive])}"
    body = Jason.encode!(%{"TableName" => t, "KeySchema" => [%{"AttributeName" => "pk", "KeyType" => "HASH"}], "AttributeDefinitions" => [%{"AttributeName" => "pk", "AttributeType" => "S"}]})
    d = signed(o, akid, secret, "dynamodb", [{"x-amz-target", "DynamoDB_20120810.CreateTable"}, {"content-type", "application/x-amz-json-1.0"}], body)
    assert d.status == 200 and d.resp_body =~ "ACTIVE"
    on_exit(fn -> Smalt.AWS.DynamoDB.dispatch("DeleteTable", %{"TableName" => t}) end)

    k = signed(o, akid, secret, "kms", [{"x-amz-target", "TrentService.CreateKey"}, {"content-type", "application/x-amz-json-1.1"}], "{}")
    assert k.status == 200 and k.resp_body =~ "KeyMetadata"
  end

  test "expired session credentials stop verifying; invalid AssumeRole args are typed errors", %{o: o} do
    cred = STS.assume_role("arn:aws:iam::123456789012:role/Short", "s", -10)
    assert STS.secret_for(cred.akid) == :error
    assert sts(o, %{"Action" => "GetCallerIdentity"}, cred.akid, cred.secret).status == 403
    bad = sts(o, %{"Action" => "AssumeRole", "RoleArn" => "arn:aws:iam::1:role/x", "RoleSessionName" => "s", "DurationSeconds" => "10"})
    assert bad.status == 400 and bad.resp_body =~ "ValidationError"
  end
end
