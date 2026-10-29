# KD-S3/KD-S4 lane: secret version history on the KV data plane.
#
# Witnessed defects:
#   KD-S3 — a superseded version id answered typed 404 SecretNotFound (the
#   store kept only the latest version per bare name); real Azure retains
#   version history (superseded GET -> 200 with THAT version per-version
#   value + attributes).
#   KD-S4 — "latest" resolved by lexically-greatest version UUID rather than
#   last-write; after a 3rd PUT, latest stayed on an earlier version.
#
# Fix: every secret PUT writes a retained version row under {name, version},
# a newest-first "versions" index on the bare-name row, and a node-monotonic
# "created_seq"; the version-addressed GET serves the retained row (typed 404
# SecretNotFound only for genuinely unknown versions); latest resolves by
# last-write (versions-index head / bare row), never by lexical UUID order.
#
# Chicago discipline: real Store ETS rows, real Plug router dispatch over the
# Plug test adapter, asserting final wire state — no mocks, no sleeps.
defmodule Smalt.Internal.KdS3S4SecretVersionHistoryTest do
  use ExUnit.Case, async: false
  alias Plug.Adapters.Test.Conn, as: TestConn

  alias Smalt.Store

  @table :smalt_vault_secrets

  setup do
    # Fail loud if the store is not booted — these are real-store courts.
    assert :ets.info(@table) != :undefined, "smalt vault secrets store not booted"
    :ok
  end

  test "KD-S3/KD-S4: 3 PUTs retain all versions; latest is the last write" do
    name = "kds3-sec-#{System.system_time(:millisecond)}"

    v1 = put_secret(name, "v1")
    v2 = put_secret(name, "v2")
    v3 = put_secret(name, "v3")

    seg1 = seg(v1["id"])
    seg2 = seg(v2["id"])
    seg3 = seg(v3["id"])

    assert seg1 != seg2 and seg2 != seg3 and seg1 != seg3

    # KD-S4: latest is the LAST WRITE. The store rows carry the write-order
    # evidence directly (versions index head + monotonic created_seq).
    {:ok, bare} = Store.get(@table, name)
    assert %{"versions" => [^seg3, ^seg2, ^seg1]} = bare
    assert {:ok, %{"created_seq" => seq3}} = Store.get(@table, {name, seg3})
    assert {:ok, %{"created_seq" => seq2}} = Store.get(@table, {name, seg2})
    assert {:ok, %{"created_seq" => seq1}} = Store.get(@table, {name, seg1})
    assert seq1 < seq2 and seq2 < seq3, "created_seq is monotonic in write order"

    # The latest GET view resolves to the 3rd PUT regardless of lexical order.
    conn = get("/secrets/#{name}")
    assert conn.status == 200
    latest = Jason.decode!(conn.resp_body)
    assert latest["id"] == v3["id"], "latest id is the last-write version id"
    assert latest["value"] == "v3"
    assert seg(latest["id"]) == seg3

    # KD-S3: every retained version answers 200 with its own value + attributes.
    for {s, val} <- [{seg1, "v1"}, {seg2, "v2"}, {seg3, "v3"}] do
      conn = get("/secrets/#{name}/#{s}")
      assert conn.status == 200, "version #{s} addressable (KD-S3)"
      body = Jason.decode!(conn.resp_body)
      assert body["value"] == val
      assert String.ends_with?(body["id"], "/secrets/#{name}/#{s}")
      assert is_integer(body["attributes"]["created"])
    end

    # Unknown version: typed 404 SecretNotFound.
    conn = get("/secrets/#{name}/00000000-0000-4000-8000-000000000000")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "SecretNotFound"

    cleanup(name)
  end

  test "KD-S3: soft delete hides history, recover restores it, purge drops it" do
    name = "kds3-del-#{System.system_time(:millisecond)}"

    v1 = put_secret(name, "del-v1")
    v2 = put_secret(name, "del-v2")
    seg1 = seg(v1["id"])
    seg2 = seg(v2["id"])

    # soft delete: live surface answers typed 404 for the name and both versions
    assert {:ok, 200, _} = Smalt.DataPlane.KeyVaultActions.delete_secret(name)
    assert :error == Store.get(@table, name)
    assert {404, %{"error" => %{"code" => "SecretNotFound"}}} = wire(name, seg1)
    assert {404, %{"error" => %{"code" => "SecretNotFound"}}} = wire(name, seg2)

    # recover: version rows restored, values intact
    assert {:ok, 200, _} = Smalt.DataPlane.KeyVaultActions.recover_deleted_secret(name)
    assert {200, %{"value" => "del-v1"}} = wire(name, seg1)
    assert {200, %{"value" => "del-v2"}} = wire(name, seg2)
    assert {:ok, %{"versions" => [^seg2, ^seg1]}} = Store.get(@table, name)

    # purge: history gone for good (re-delete first — recover emptied the
    # deleted-bundle table)
    assert {:ok, 200, _} = Smalt.DataPlane.KeyVaultActions.delete_secret(name)
    assert {:ok, 204, _} = Smalt.DataPlane.KeyVaultActions.purge_deleted_secret(name)
    assert {404, _} = wire(name, seg1)
    assert {404, _} = wire(name, seg2)
    assert :error == Store.get(@table, name)
  end

  test "KD-S3: PATCH on a superseded version updates only that version's row" do
    name = "kds3-patch-#{System.system_time(:millisecond)}"

    v1 = put_secret(name, "patch-v1")
    v2 = put_secret(name, "patch-v2")
    seg1 = seg(v1["id"])
    seg2 = seg(v2["id"])

    assert {:ok, 200, patched} =
             Smalt.DataPlane.KeyVaultActions.update_secret_properties(name, %{
               "attributes" => %{"enabled" => false}
             }, seg1)

    assert patched["attributes"]["enabled"] == false

    # only the superseded row changed: latest still enabled, v2 value intact
    conn = get("/secrets/#{name}")
    assert Jason.decode!(conn.resp_body)["attributes"]["enabled"] == true
    assert {200, %{"value" => "patch-v2", "attributes" => %{"enabled" => true}}} = wire(name, seg2)
    assert {200, %{"value" => "patch-v1", "attributes" => %{"enabled" => false}}} = wire(name, seg1)

    # PATCH via the wire with a mismatched/unknown version: typed 404
    conn = patch(name, "00000000-0000-4000-8000-000000000000", %{"attributes" => %{"enabled" => false}})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "SecretNotFound"

    cleanup(name)
  end

  # ---------------------------------------------------------------------------
  # wire helpers (real router dispatch over the Plug test adapter)
  # ---------------------------------------------------------------------------

  defp seg(id), do: id |> String.split("/") |> List.last()

  defp put_secret(name, value) do
    conn =
      %Plug.Conn{}
      |> TestConn.conn("PUT", "/secrets/#{name}", "")
      |> Map.put(:body_params, %{"value" => value})

    conn = Smalt.Egress.KvRoutes.call(conn, [])
    assert conn.status in [200, 201], "PUT /secrets/#{name} -> #{conn.status}"
    Jason.decode!(conn.resp_body)
  end

  defp get(path) do
    %Plug.Conn{}
    |> TestConn.conn("GET", path, "")
    |> Smalt.Egress.KvRoutes.call([])
  end

  defp patch(name, version, body) do
    %Plug.Conn{}
    |> TestConn.conn("PATCH", "/secrets/#{name}/#{version}", "")
    |> Map.put(:body_params, body)
    |> Smalt.Egress.KvRoutes.call([])
  end

  # Wire-level {status, decoded body} probe through the router.
  defp wire(name, version) do
    conn = get("/secrets/#{name}/#{version}")
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp cleanup(name) do
    Smalt.DataPlane.KeyVaultActions.delete_secret(name)
    Smalt.DataPlane.KeyVaultActions.purge_deleted_secret(name)
  end
end
