# KD-LITH-WIRE-2 lane: GET /secrets/{name}/versions — the documented KV 7.4
# versions-list shape (200 {value: [SecretBundle...], nextLink}) projected
# from the KD-S3 retained version rows, newest-first.
#
# Previously a 501 NotImplemented refusal (tape af-14); the G5 wave already
# retained {name, version} rows + the newest-first "versions" index — this
# lane surfaces them on the wire.
#
# Chicago discipline: real Store ETS rows, real Plug router dispatch over the
# Plug test adapter, asserting final wire state — no mocks, no sleeps.
defmodule Smalt.Internal.KdLithW2VersionsListTest do
  use ExUnit.Case, async: false
  alias Plug.Adapters.Test.Conn, as: TestConn

  @table :smalt_vault_secrets

  setup do
    assert :ets.info(@table) != :undefined, "smalt vault secrets store not booted"
    :ok
  end

  test "3 PUTs -> versions list answers 3 documented bundles newest-first" do
    name = "kdlith-w2-#{System.system_time(:millisecond)}"

    for val <- ["v1", "v2", "v3"] do
      conn =
        %Plug.Conn{}
        |> TestConn.conn("PUT", "/secrets/#{name}", "")
        |> Map.put(:body_params, %{"value" => val})
        |> Smalt.Egress.KvRoutes.call([])

      assert conn.status in [200, 201], "PUT -> #{conn.status}"
    end

    conn =
      %Plug.Conn{}
      |> TestConn.conn("GET", "/secrets/#{name}/versions", "")
      |> Smalt.Egress.KvRoutes.call([])

    assert conn.status == 200, "versions list -> #{conn.status}"

    body = Jason.decode!(conn.resp_body)
    assert %{"value" => value} = body
    assert length(value) == 3, "3 retained versions listed, got #{length(value)}"

    # newest-first: each bundle's value reads v3, v2, v1 in order
    assert Enum.map(value, & &1["value"]) == ["v3", "v2", "v1"]

    # documented SecretBundle members on every entry
    for bundle <- value do
      assert is_binary(bundle["id"])
      assert String.starts_with?(bundle["id"], "https://")
      assert String.contains?(bundle["id"], "/secrets/#{name}/")
      assert is_integer(bundle["attributes"]["created"])
      assert is_integer(bundle["attributes"]["updated"])
      assert is_boolean(bundle["attributes"]["enabled"])
    end

    # nextLink absent (single-page history; documented absent-nextLink shape)
    refute Map.has_key?(body, "nextLink")

    # ids descend in write order: the newest id is the bare-row latest id
    conn =
      %Plug.Conn{}
      |> TestConn.conn("GET", "/secrets/#{name}", "")
      |> Smalt.Egress.KvRoutes.call([])

    latest = Jason.decode!(conn.resp_body)
    assert hd(value)["id"] == latest["id"], "index head is the last-write version"
  end

  test "unknown / scrubbed name -> 200 with empty value (no 404 lie)" do
    name = "kdlith-w2-empty-#{System.system_time(:millisecond)}"

    conn =
      %Plug.Conn{}
      |> TestConn.conn("GET", "/secrets/#{name}/versions", "")
      |> Smalt.Egress.KvRoutes.call([])

    assert conn.status == 200
    assert %{"value" => []} = Jason.decode!(conn.resp_body)
  end
end
