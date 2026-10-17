defmodule Smalt.DataPlane.R133PolicyCasTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.BlobService
  alias Smalt.Store

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    BlobStorage.ensure_policy_table()
    :ets.delete_all_objects(:smalt_blob_policy)
    :ok
  end

  # R133 exploit probe (W5-8): set_container_metadata + set_legal_hold were
  # unlocked read-modify-writes on the shared :smalt_blob_policy row — a
  # metadata PUT writing back a row read before a committed hold silently
  # cleared it (W5-8: 2884/6400 lost holds). Both writers now serialize
  # through Store.compare_and_swap / insert_new (BlobStorage.cas_policy_row):
  # a stale write-back conflicts, retries, re-reads the hold, refuses 409.
  test "concurrent metadata PUTs vs hold-sets: committed holds are never lost (W5-8 race)" do
    account = "r133"
    container = "cont1"

    {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})
    parent = self()

    for round <- 1..500 do
      :ets.delete_all_objects(:smalt_blob_policy)

      tasks =
        for i <- 1..64 do
          Task.async(fn ->
            receive do
              :go -> :ok
            end

            if rem(i, 2) == 0 do
              send(parent, {:r133_meta, round, i, BlobService.set_container_metadata(account, container, %{"k#{i}" => "v#{i}"})})
            else
              send(parent, {:r133_hold, round, i, BlobStorage.set_legal_hold(account, container, true)})
            end
          end)
        end

      Enum.each(tasks, fn task -> send(task.pid, :go) end)

      holds = collect(parent, :r133_hold, round, 32, [])
      bad = collect(parent, :r133_meta, round, 32, [])

      Enum.each(holds, fn r ->
        assert {:ok, 200, _, _} = r
      end)

      Enum.each(bad, fn r ->
        case r do
          {:ok, 200, _} -> :ok
          {:error, 409, "ContainerLocked", _} -> :ok
          other -> flunk("unexpected metadata PUT outcome: #{inspect(other)}")
        end
      end)

      # invariant: with all hold-sets true and no false-set ever issued, the
      # final row must carry the hold — a stale metadata write-back that
      # linearized last is the W5-8 HOLD_LOST signature
      assert {:ok, policy} = Store.get(:smalt_blob_policy, "#{account}/#{container}")

      assert policy["legal_hold"] == true,
             "HOLD_LOST in round #{round}: #{inspect(policy)}"
    end
  end

  defp collect(_parent, _tag, _round, 0, acc), do: Enum.reverse(acc)

  defp collect(parent, tag, round, n, acc) do
    receive do
      {^tag, ^round, _i, r} -> collect(parent, tag, round, n - 1, [r | acc])
    after
      30_000 -> flunk("racer timed out waiting for #{tag} round #{round}")
    end
  end

  # Deterministic W5-8 interleave at the repair seam: the "concurrent hold
  # commit" happens INSIDE the update fn, between cas_policy_row's row read
  # and its CAS write-back. A serialized CAS must conflict, retry, re-read
  # the row that now carries the hold, and merge — preserving it. A plain
  # read-modify-write (the pre-R133 writers) writes back the stale row and
  # deterministically clears the committed hold.
  test "cas_policy_row: hold committed between read and write-back is preserved, not clobbered" do
    account = "r133d"
    container = "cont4"

    {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})

    key = "#{account}/#{container}"

    # base row: metadata, no hold (the stale view the writer starts from);
    # the hold is committed concurrently INSIDE the update fn (below)
    :ets.insert(:smalt_blob_policy, {key, %{"metadata" => %{"old" => "1"}}})

    :ok =
      BlobStorage.cas_policy_row(key, fn policy ->
        if policy["legal_hold"] == true do
          # retry pass: the row now carries the committed hold — merge into it
          {:ok, Map.put(policy, "metadata", %{"new" => "2"})}
        else
          # first pass: simulate the concurrent committer landing the hold
          # between our read and our write-back
          {:ok, 200, _, _} = BlobStorage.set_legal_hold(account, container, true)
          {:ok, Map.put(policy, "metadata", %{"new" => "2"})}
        end
      end)

    {:ok, final} = Store.get(:smalt_blob_policy, key)

    assert final["legal_hold"] == true,
           "HOLD_LOST: cas_policy_row wrote back a stale row and cleared the concurrently committed hold: #{inspect(final)}"

    assert final["metadata"] == %{"new" => "2"}
  end

  test "serialized 409 gate still works: metadata PUT under an already-committed hold is ContainerLocked" do
    account = "r133b"
    container = "cont2"

    {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})
    assert {:ok, 200, _, _} = BlobStorage.set_legal_hold(account, container, true)

    assert {:error, 409, "ContainerLocked", _} =
             BlobService.set_container_metadata(account, container, %{"a" => "b"})
  end

  test "metadata PUT still succeeds on a hold-free container (non-vacuity of the happy path)" do
    account = "r133c"
    container = "cont3"

    {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})

    assert {:ok, 200, _} = BlobService.set_container_metadata(account, container, %{"a" => "b"})
    {:ok, policy} = Store.get(:smalt_blob_policy, "#{account}/#{container}")
    assert policy["metadata"] == %{"a" => "b"}
  end
end
