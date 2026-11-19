defmodule Smalt.Aoq.Session.Lease.FenceTest do
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Session.Lease.Fence

  defp frame(epoch, ordinal),
    do: %Frame{epoch: epoch, key_id: 1, frame_ordinal: ordinal, seq: 0}

  defp bound(epoch \\ :rotated_1, generation \\ 7) do
    {:ok, lease} = Fence.bind("lease-a", epoch, generation)
    lease
  end

  test "frame at the bound lease epoch and generation is admitted and encodes on the wire" do
    lease = bound()
    f = frame(1, 7)
    assert :ok = Fence.check(lease, "lease-a", f)
    assert {:ok, [header, _body]} = Frame.encode_frame(f, <<1, 2, 3>>)
    assert byte_size(header) == 64
  end

  test "frame with previous valid epoch after renewal is stale; state unchanged" do
    lease = bound(:rotated_1, 7)
    {:ok, renewed} = Fence.renew(lease, :rotated_2, 8)
    before = renewed

    assert {:error, {:stale_frame, {:epoch, 1, 2}}} = Fence.check(renewed, "lease-a", frame(1, 8))
    assert renewed == before
    assert :ok = Fence.check(renewed, "lease-a", frame(2, 8))
  end

  test "frame with previous generation after renewal is stale; state unchanged" do
    lease = bound(:rotated_1, 7)
    {:ok, renewed} = Fence.renew(lease, :rotated_1, 8)
    before = renewed

    assert {:error, {:stale_frame, {:generation, 7, 8}}} =
             Fence.check(renewed, "lease-a", frame(1, 7))

    assert renewed == before
  end

  test "frame naming a lease id never bound is refused as unbound" do
    assert {:error, {:unbound_lease, "other"}} = Fence.check(bound(), "other", frame(1, 7))
  end

  test "generation ahead is refused, renewal regression and retired epoch are refused" do
    lease = bound()
    assert {:error, {:generation_ahead, {9, 7}}} = Fence.check(lease, "lease-a", frame(1, 9))
    assert {:error, {:lease_regression, _}} = Fence.renew(lease, :genesis, 8)
    assert {:error, {:lease_regression, _}} = Fence.renew(lease, :rotated_1, 7)
    assert {:error, :retired_epoch} = Fence.bind("x", :retired, 0)
  end
end
