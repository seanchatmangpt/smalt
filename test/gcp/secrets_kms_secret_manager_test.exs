defmodule Smalt.GCP.SecretsKmsSecretManagerTest do
  use ExUnit.Case, async: true
  alias Smalt.GCP.SecretManager, as: SM

  setup do
    {:ok, pid} = SM.start_link(name: nil)
    {:ok, pid: pid}
  end

  @base "/v1/projects/p1/secrets"

  test "create, add versions, access latest and pinned, lifecycle", %{pid: s} do
    assert {200, _} = SM.handle(s, "POST", @base, %{"secretId" => "db"}, %{})
    assert {409, _} = SM.handle(s, "POST", @base, %{"secretId" => "db"}, %{})
    pl = fn d -> %{"payload" => %{"data" => Base.encode64(d)}} end
    assert {200, %{"name" => n1}} = SM.handle(s, "POST", @base <> "/db:addVersion", %{}, pl.("one"))
    assert String.ends_with?(n1, "/versions/1")
    assert {200, _} = SM.handle(s, "POST", @base <> "/db:addVersion", %{}, pl.("two"))

    assert {200, %{"payload" => %{"data" => d}}} = SM.handle(s, "POST", @base <> "/db/versions/latest:access")
    assert Base.decode64!(d) == "two"
    assert {200, %{"payload" => %{"data" => d1}}} = SM.handle(s, "POST", @base <> "/db/versions/1:access")
    assert Base.decode64!(d1) == "one"

    assert {200, %{"state" => "DISABLED"}} = SM.handle(s, "POST", @base <> "/db/versions/2:disable")
    assert {400, %{"error" => %{"status" => "FAILED_PRECONDITION"}}} = SM.handle(s, "POST", @base <> "/db/versions/2:access")
    # latest skips disabled
    assert {200, %{"payload" => %{"data" => d3}}} = SM.handle(s, "POST", @base <> "/db/versions/latest:access")
    assert Base.decode64!(d3) == "one"
    assert {200, %{"state" => "ENABLED"}} = SM.handle(s, "POST", @base <> "/db/versions/2:enable")
    assert {200, %{"state" => "DESTROYED"}} = SM.handle(s, "POST", @base <> "/db/versions/2:destroy")
    assert {400, _} = SM.handle(s, "POST", @base <> "/db/versions/2:enable")
    assert {200, %{"totalSize" => 2}} = SM.handle(s, "GET", @base <> "/db/versions")
    assert {200, %{"secrets" => [_]}} = SM.handle(s, "GET", @base)
    assert {200, _} = SM.handle(s, "DELETE", @base <> "/db")
    assert {404, _} = SM.handle(s, "GET", @base <> "/db")
  end

  test "bad payload and missing secret", %{pid: s} do
    assert {404, _} = SM.handle(s, "POST", @base <> "/nope:addVersion", %{}, %{"payload" => %{"data" => "AA=="}})
    SM.handle(s, "POST", @base, %{"secretId" => "x"}, %{})
    assert {400, _} = SM.handle(s, "POST", @base <> "/x:addVersion", %{}, %{"payload" => %{"data" => "!!"}})
  end
end
