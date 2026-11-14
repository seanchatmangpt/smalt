defmodule Smalt.AWS.SecretsManagerTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.AWS.SigV4
  alias Smalt.AWS.SecretsManager.Router

  @creds %{"AKIDTEST" => "secretTEST"}

  setup do
    name = :"sm_#{System.unique_integer([:positive])}"
    start_supervised!({Smalt.AWS.SecretsManager, name: name})
    {:ok, o: Router.init(server: name, creds: @creds)}
  end

  defp call(o, op, payload, secret \\ "secretTEST") do
    body = Jason.encode!(payload)
    date = "20260101T000000Z"
    hs = [{"host", "localhost"}, {"x-amz-date", date}, {"x-amz-target", "secretsmanager." <> op},
          {"content-type", "application/x-amz-json-1.1"}]
    auth = SigV4.sign(%{method: "POST", path: "/", query: "", headers: hs, body: body, access_key_id: "AKIDTEST",
                        secret: secret, region: "us-east-1", service: "secretsmanager", amz_date: date})
    c = Enum.reduce(hs, conn("POST", "/", body), fn {k, v}, c -> %{c | req_headers: c.req_headers ++ [{k, v}]} end)
    r = Router.call(put_req_header(c, "authorization", auth), o)
    {r.status, Jason.decode!(r.resp_body)}
  end

  test "bad signature refused", %{o: o} do
    assert {400, %{"__type" => "InvalidSignatureException"}} = call(o, "ListSecrets", %{}, "wrong")
  end

  test "create/get, duplicate refused, missing typed", %{o: o} do
    assert {200, %{"ARN" => arn, "VersionId" => _}} = call(o, "CreateSecret", %{"Name" => "db", "SecretString" => "p1"})
    assert arn =~ "arn:aws:secretsmanager:us-east-1:000000000000:secret:db-"
    assert {200, %{"SecretString" => "p1", "VersionStages" => ["AWSCURRENT"]}} = call(o, "GetSecretValue", %{"SecretId" => "db"})
    assert {400, %{"__type" => "ResourceExistsException"}} = call(o, "CreateSecret", %{"Name" => "db", "SecretString" => "x"})
    assert {400, %{"__type" => "ResourceNotFoundException"}} = call(o, "GetSecretValue", %{"SecretId" => "nope"})
  end

  test "version stages rotate CURRENT -> PREVIOUS", %{o: o} do
    {200, %{"VersionId" => v1}} = call(o, "CreateSecret", %{"Name" => "k", "SecretString" => "one"})
    {200, %{"VersionId" => v2}} = call(o, "PutSecretValue", %{"SecretId" => "k", "SecretString" => "two"})
    {200, %{"VersionId" => v3}} = call(o, "PutSecretValue", %{"SecretId" => "k", "SecretString" => "three"})
    assert {200, %{"SecretString" => "three"}} = call(o, "GetSecretValue", %{"SecretId" => "k"})
    assert {200, %{"SecretString" => "two", "VersionId" => ^v2}} = call(o, "GetSecretValue", %{"SecretId" => "k", "VersionStage" => "AWSPREVIOUS"})
    assert {200, %{"VersionIdsToStages" => m}} = call(o, "DescribeSecret", %{"SecretId" => "k"})
    assert m[v3] == ["AWSCURRENT"] and m[v2] == ["AWSPREVIOUS"] and m[v1] == []
    assert {200, %{"SecretString" => "one"}} = call(o, "GetSecretValue", %{"SecretId" => "k", "VersionId" => v1})
  end

  test "soft delete blocks reads, restore recovers, force delete removes", %{o: o} do
    call(o, "CreateSecret", %{"Name" => "d", "SecretString" => "v"})
    assert {200, %{"DeletionDate" => _}} = call(o, "DeleteSecret", %{"SecretId" => "d"})
    assert {400, %{"__type" => "InvalidRequestException"}} = call(o, "GetSecretValue", %{"SecretId" => "d"})
    assert {200, _} = call(o, "RestoreSecret", %{"SecretId" => "d"})
    assert {200, %{"SecretString" => "v"}} = call(o, "GetSecretValue", %{"SecretId" => "d"})
    assert {200, _} = call(o, "DeleteSecret", %{"SecretId" => "d", "ForceDeleteWithoutRecovery" => true})
    assert {400, %{"__type" => "ResourceNotFoundException"}} = call(o, "DescribeSecret", %{"SecretId" => "d"})
  end
end
