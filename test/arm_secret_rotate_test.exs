defmodule Smalt.ArmSecretRotateTest do
  @moduledoc """
  ARM secret rotation trigger (v26.10.16 console C4 server-side half):
  POST /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.KeyVault/
  vaults/:vault/secrets/:secret/rotate?api-version=... bumps the data-plane
  version (value carried forward) and answers with the ARM secret envelope
  carrying the NEW version id. Cross-plane: the rotated version is GET-able on
  the 8443 data plane by version.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.EgressRouter
  alias Smalt.Store

  @arm_opts Router.init([])
  @egress_opts EgressRouter.init([])

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    :ok
  end

  defp arm(method, path, body \\ %{}) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@arm_opts)
  end

  defp egress(method, path, headers \\ []) do
    conn(method, path, "")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> EgressRouter.call(@egress_opts)
  end

  @bearer [{"authorization", "Bearer rotate-harness"}]

  defp put_vault(vault) do
    conn(
      :put,
      "/subscriptions/sub-rot/resourceGroups/rg-rot/providers/Microsoft.KeyVault/vaults/#{vault}?api-version=2021-04-01",
      Jason.encode!(%{
        "location" => "eastus",
        "properties" => %{"sku" => %{"name" => "standard", "family" => "A"}}
      })
    )
    |> put_req_header("content-type", "application/json")
    |> Router.call(@arm_opts)
    |> tap(fn c -> assert c.status == 201 end)
  end

  defp put_secret(vault, name, value) do
    conn(
      :put,
      "/subscriptions/sub-rot/resourceGroups/rg-rot/providers/Microsoft.KeyVault/vaults/#{vault}/secrets/#{name}?api-version=2023-07-01",
      Jason.encode!(%{"location" => "eastus", "properties" => %{"value" => value}})
    )
    |> put_req_header("content-type", "application/json")
    |> Router.call(@arm_opts)
  end

  defp rotate_path(vault, name),
    do:
      "/subscriptions/sub-rot/resourceGroups/rg-rot/providers/Microsoft.KeyVault/vaults/#{vault}/secrets/#{name}/rotate?api-version=2023-07-01"

  test "rotate bumps version; new version GET-able by version on data plane" do
    put_vault("kv-rot")
    assert put_secret("kv-rot", "s-rot", "v1").status in [200, 201]

    before = egress(:get, "/secrets/s-rot", @bearer)
    assert before.status == 200
    before_body = Jason.decode!(before.resp_body)
    assert before_body["value"] == "v1"

    before_version = before_body["id"] |> String.split("/") |> List.last()

    conn = arm(:post, rotate_path("kv-rot", "s-rot"))
    assert conn.status == 200, inspect(conn.resp_body)
    envelope = Jason.decode!(conn.resp_body)
    assert envelope["properties"]["version"]
    assert envelope["properties"]["version"] != before_version

    # version id bumped on the data plane too (id suffix carries the version)
    latest = egress(:get, "/secrets/s-rot", @bearer)
    assert latest.status == 200
    latest_body = Jason.decode!(latest.resp_body)
    assert latest_body["id"] |> String.split("/") |> List.last() ==
             envelope["properties"]["version"]

    # value carried forward
    assert latest_body["value"] == "v1"

    # the NEW version is GET-able BY VERSION on the data plane
    by_version = egress(:get, "/secrets/s-rot/#{envelope["properties"]["version"]}", @bearer)
    assert by_version.status == 200, inspect(by_version.resp_body)
    assert Jason.decode!(by_version.resp_body)["value"] == "v1"

    # a non-latest version is a typed 404, not a splat fall-through
    stale = egress(:get, "/secrets/s-rot/999-stale", @bearer)
    assert {404, "SecretNotFound"} = {stale.status, Jason.decode!(stale.resp_body)["error"]["code"]}
  end

  test "rotate unknown secret -> typed 404" do
    put_vault("kv-rot-2")

    conn = arm(:post, rotate_path("kv-rot-2", "nope"))
    assert {404, "ResourceNotFound"} = {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]}
  end

  test "rotate with no parent vault -> typed 404" do
    conn = arm(:post, rotate_path("kv-absent", "s-x"))
    assert {404, "ResourceNotFound"} = {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]}
  end

  test "rotate with no data-plane version to carry forward -> typed 409" do
    put_vault("kv-rot-3")

    # Seed then drop the data-plane record: an ARM record with no prior version
    # (control-plane-only PUT, or swept row) has nothing to rotate.
    assert put_secret("kv-rot-3", "s-ctl", "v").status in [200, 201]
    Store.delete(:smalt_vault_secrets, "s-ctl")

    conn = arm(:post, rotate_path("kv-rot-3", "s-ctl"))
    assert {409, "SecretVersionNotFound"} =
             {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]}
  end
end