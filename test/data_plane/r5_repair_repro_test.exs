defmodule Smalt.DataPlane.R5RepairReproTest do
  @moduledoc """
  Repair lane R5 repro tests (audit A1 verified defects on
  lib/smalt/data_plane/blob_storage.ex). Kept as regression coverage.
  """
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.Store

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    BlobStorage.ensure_policy_table()
    :ets.delete_all_objects(:smalt_blob_policy)
    :ok
  end

  defp container(account \\ "r5a", name \\ "c001") do
    {:ok, _} = BlobStorage.create_container(account, name, %{"immutable" => false})
    {account, name}
  end

  test "put_blob create under legal hold -> :worm_locked (was: silently created)" do
    container()
    {:ok, 200, _, _} = BlobStorage.set_legal_hold("r5a", "c001", true)

    assert {:error, :worm_locked, msg} =
             BlobStorage.put_blob("r5a", "c001", "brand-new", "x")

    assert msg =~ "legal hold"

    # Refusal must not have created the blob
    assert :error = BlobStorage.get_blob("r5a", "c001", "brand-new")
  end

  test "put_blob create allowed again after hold release" do
    container()
    {:ok, 200, _, _} = BlobStorage.set_legal_hold("r5a", "c001", true)
    {:ok, 200, _, _} = BlobStorage.set_legal_hold("r5a", "c001", false)

    assert {:ok, _} = BlobStorage.put_blob("r5a", "c001", "after-release", "x")
  end

  test "parse_block_list_xml maps all three kinds without to_existing_atom" do
    xml = "<Block><Latest>a</Latest><Committed>b</Committed><Uncommitted>c</Uncommitted></Block>"

    assert {:ok, [latest: "a", committed: "b", uncommitted: "c"]} =
             BlobStorage.parse_block_list_xml(xml)
  end
end
