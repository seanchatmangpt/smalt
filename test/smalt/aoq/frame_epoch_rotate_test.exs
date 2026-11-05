defmodule Smalt.Aoq.FrameEpochRotateTest do
  # persistent_term tables are node-global: boot is synchronous and each
  # test re-derives its own table contents (structural sync, no sleeps).
  use ExUnit.Case, async: false

  alias Smalt.Aoq.{Frame, Tables}

  setup do
    on_exit(fn -> Tables.boot() end)
    :ok
  end

  defp rotate_frame(current_epoch, new_epoch, seq \\ 7) do
    frame = %Frame{
      epoch: current_epoch,
      seq: seq,
      type: 0x03,
      flags: 0,
      payload_len: 2
    }

    {:ok, [header, payload]} = Frame.encode_frame(frame, <<new_epoch::unsigned-integer-size(16)>>)

    assert {:ok, {decoded, ^payload}} = Frame.decode(header <> payload)
    decoded
  end

  @tag :l38
  test "lawful rotate: 0x03 frame appends the new epoch via the whole-map path" do
    Tables.boot(
      frame_types: %{0x03 => {Frame, :handle_epoch_rotate}},
      epochs: %{0 => {:genesis, 0}}
    )

    frame = rotate_frame(0, 1)
    assert frame.type == 0x03

    assert :ok = Frame.handle_epoch_rotate(frame, <<1::unsigned-integer-size(16)>>)
    epochs = Tables.epochs()

    # append-only: old epoch retained, new epoch present
    assert epochs == %{0 => {:genesis, 0}, 1 => {:rotated_from, 0, 7}}
  end

  @tag :l38
  test "stale/regressing epoch is refused as a typed error, table untouched" do
    Tables.boot(
      frame_types: %{0x03 => {Frame, :handle_epoch_rotate}},
      epochs: %{0 => {:genesis, 0}, 5 => {:rotated_from, 0, 3}}
    )

    frame = rotate_frame(5, 2)
    assert {:error, {:epoch_regression, 2, 5}} = Frame.handle_epoch_rotate(frame, <<2::16>>)
    assert Tables.epochs() == %{0 => {:genesis, 0}, 5 => {:rotated_from, 0, 3}}
  end

  @tag :l38
  test "rotate to an existing epoch id is a regression (append-only law)" do
    Tables.boot(
      frame_types: %{0x03 => {Frame, :handle_epoch_rotate}},
      epochs: %{0 => {:genesis, 0}, 1 => {:rotated_from, 0, 1}}
    )

    frame = rotate_frame(1, 1)
    assert {:error, {:epoch_regression, 1, 1}} = Frame.handle_epoch_rotate(frame, <<1::16>>)
    assert Tables.epochs() == %{0 => {:genesis, 0}, 1 => {:rotated_from, 0, 1}}
  end

  @tag :l38
  test "pre-boot rotate is a typed refusal, seal absent" do
    # Unseal: restore the pre-boot world by dropping the seal key only.
    :persistent_term.erase({:aoq, :sealed})
    assert Tables.sealed?() == false

    frame = %Frame{epoch: 0, seq: 1, type: 0x03, flags: 0, payload_len: 2}
    assert {:error, :tables_unbooted} = Frame.handle_epoch_rotate(frame, <<1::16>>)
    assert Tables.epochs() == %{}
  end

  @tag :l38
  test "malformed rotate payload (not exactly 2 bytes) is a typed refusal" do
    Tables.boot(
      frame_types: %{0x03 => {Frame, :handle_epoch_rotate}},
      epochs: %{0 => {:genesis, 0}}
    )

    frame = %Frame{epoch: 0, seq: 1, type: 0x03, flags: 0, payload_len: 3}
    assert {:error, {:bad_rotate_payload, <<1, 2, 3>>}} =
             Frame.handle_epoch_rotate(frame, <<1, 2, 3>>)

    assert Tables.epochs() == %{0 => {:genesis, 0}}
  end
end
