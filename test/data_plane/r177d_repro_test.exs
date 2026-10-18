defmodule Smalt.DataPlane.R177dReproTest do
  use ExUnit.Case, async: false
  alias Smalt.DataPlane.{BlobStorage, BlobService}
  alias Smalt.Store

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    BlobStorage.ensure_policy_table()
    :ets.delete_all_objects(:smalt_blob_policy)
    :ok
  end

  test "R177d: metadata PUT -> immutability PUT -> metadata survives" do
    {:ok, _} = BlobStorage.create_container("r177d", "c1x", %{"immutable" => false})
    {:ok, 200, _} = BlobService.set_container_metadata("r177d", "c1x", %{"m" => "v"})

    {:ok, _, _, _} =
      BlobStorage.set_immutability_policy("r177d", "c1x", %{"period_days" => 1}, %{
        "if-match" => "*"
      })

    assert {:ok, %{"m" => "v"}} = BlobService.get_container_metadata("r177d", "c1x")
  end

  test "R177d: immutability PUT -> metadata PUT under hold -> 409" do
    {:ok, _} = BlobStorage.create_container("r177d", "c2x", %{"immutable" => false})

    {:ok, _, _, _} =
      BlobStorage.set_immutability_policy("r177d", "c2x", %{"period_days" => 1}, %{
        "if-match" => "*"
      })

    {:ok, _, _, _} = BlobStorage.set_legal_hold("r177d", "c2x", true)
    assert {:error, 409, _, _} = BlobService.set_container_metadata("r177d", "c2x", %{"a" => "b"})
  end

  test "R177d: legal_hold survives immutability PUT" do
    {:ok, _} = BlobStorage.create_container("r177d", "c3x", %{"immutable" => false})
    {:ok, _, _, _} = BlobStorage.set_legal_hold("r177d", "c3x", true)

    {:ok, _, _, _} =
      BlobStorage.set_immutability_policy("r177d", "c3x", %{"period_days" => 1}, %{
        "if-match" => "*"
      })

    final = BlobStorage.get_policy("r177d", "c3x") || %{}
    assert Map.get(final, "legal_hold") == true
  end

  test "R177d: concurrent hold-vs-immutability storm, no lost updates" do
    {:ok, _} = BlobStorage.create_container("r177d", "c4x", %{"immutable" => false})
    parent = self()

    Enum.each(1..40, fn _ ->
      spawn(fn ->
        {:ok, 200, _, _} = BlobStorage.set_legal_hold("r177d", "c4x", true)
        send(parent, :done)
      end)

      spawn(fn ->
        BlobStorage.set_immutability_policy("r177d", "c4x", %{"period_days" => 1}, %{}, [])
        send(parent, :done)
      end)
    end)

    Enum.each(1..80, fn _ ->
      receive do
        :done -> :ok
      end
    end)

    final = BlobStorage.get_policy("r177d", "c4x") || %{}
    assert Map.get(final, "legal_hold") == true
    imm = Map.get(final, "immutability_policy") || %{}
    assert is_map(imm)
    assert Map.get(imm, "period_days") == 1
    assert Map.get(final, "metadata") == nil
  end
end
