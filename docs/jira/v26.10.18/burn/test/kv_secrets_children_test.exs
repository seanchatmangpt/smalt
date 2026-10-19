defmodule Smalt.KvSecretsChildrenTest do
  @moduledoc """
  ARM control-plane child routes for Microsoft.KeyVault/vaults/secrets
  (lane 361, v26.10.16) + the cross-plane seed: an ARM secret PUT (9443)
  writes a record into the data-plane secrets store (:smalt_vault_secrets)
  so a data-plane GET /secrets/:name (8443) returns the value.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])

  setup do
    # Canonical resilient shared-Store setup: the bare ensure_store_up +
    # Store.clear() window races an async sibling's shared-tree teardown
    # (FLAKE_LEDGER F2-F5) — the clear is retried inside the bounded window.
    SmaltTest.Store.resilient_setup()
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp code(conn), do: body(conn)["error"]["code"]

  defp put_vault(vault) do
    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.KeyVault/vaults/#{vault}?api-version=2021-04-01",
      %{
        "location" => "eastus",
        "properties" => %{"sku" => %{"name" => "standard", "family" => "A"}}
      }
    )
    |> call()
    |> tap(fn c -> assert c.status == 201 end)
  end

  defp secret_path(vault, name),
    do:
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.KeyVault/vaults/#{vault}/secrets/#{name}"

  @secret_body %{
    "location" => "eastus",
    "properties" => %{"value" => "s3cret!", "contentType" => "text/plain"}
  }

  test "full lifecycle: 201 PUT, 200 re-PUT, GET, LIST, DELETE, GET 404" do
    put_vault("kv-1")
    path = secret_path("kv-1", "s-1") <> "?api-version=2023-07-01"

    put_conn = conn(:put, path, @secret_body) |> call()
    assert put_conn.status == 201
    record = body(put_conn)
    assert record["type"] == "Microsoft.KeyVault/vaults/secrets"
    assert record["name"] == "s-1"

    reconn = conn(:put, path, @secret_body) |> call()
    assert reconn.status == 200

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200

    list_path =
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.KeyVault/vaults/kv-1/secrets?api-version=2023-07-01"

    list_conn = conn(:get, list_path) |> call()

    assert list_conn.status == 200
    assert %{"value" => items} = Jason.decode!(list_conn.resp_body)
    assert Enum.map(items, & &1["name"]) == ["s-1"]

    del_conn = conn(:delete, path) |> call()
    assert del_conn.status == 200

    gone = conn(:get, path) |> call()
    assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
  end

  test "missing parent vault -> 404 ResourceNotFound, no data-plane seed" do
    path = secret_path("kv-absent", "s-x") <> "?api-version=2023-07-01"

    conn = conn(:put, path, @secret_body) |> call()
    assert {404, "ResourceNotFound"} = {conn.status, code(conn)}
    assert Store.get(:smalt_vault_secrets, "s-x") == :error
  end

  test "cross-plane seed: ARM PUT visible on data-plane GET /secrets/:name" do
    put_vault("kv-2")
    path = secret_path("kv-2", "s-2") <> "?api-version=2023-07-01"

    put_conn = conn(:put, path, @secret_body) |> call()
    assert put_conn.status == 201

    # data-plane surface
    dconn =
      conn(:get, "/secrets/s-2")
      |> put_req_header("authorization", "Bearer kv-seed-harness")
      |> Smalt.EgressRouter.call(Smalt.EgressRouter.init([]))

    assert dconn.status == 200
    got = Jason.decode!(dconn.resp_body)
    assert got["value"] == "s3cret!"
    assert got["contentType"] == "text/plain"
    assert got["attributes"]["enabled"] == true
  end
end
