defmodule Smalt.Aoq.FrameEpochRotateTest do
  # persistent_term tables are node-global: boot is synchronous and each
  # test re-derives its own table contents (structural sync, no sleeps).
  use ExUnit.Case, async: false

  alias Smalt.Aoq.{Frame, Tables}

  setup do
    on_exit(fn -> Tables.boot() end)
    :ok
  end

  # v3 contract: a control-stream rotate frame carries the stream prefix
  # 1 (aoq:stream-control) followed by the new epoch id as u16 BE.
  defp rotate_frame(current_epoch, new_epoch, seq \\ 7) do
    frame = %Frame{
      epoch: current_epoch,
      key_id: 0x0102030405060708,
      frame_ordinal: 7,
      seq: seq
    }

    body = <<1, new_epoch::unsigned-integer-size(16)>>
    {:ok, [header, ^body]} = Frame.encode_frame(frame, body)

    assert {:ok, {decoded, ^body}} = Frame.decode(header <> body)
    decoded
  end

  @tag :l38
  test "lawful rotate: control-stream frame appends the new epoch via the whole-map path" do
    Tables.boot(
      frame_types: %{0 => {Frame, :handle_data}, 1 => {Frame, :handle_control}, 2 => {Frame, :handle_eos}},
      epochs: %{0 => {:genesis, 0}}
    )

    frame = rotate_frame(0, 1)

    assert :ok = Frame.handle_epoch_rotate(frame, <<1, 1::unsigned-integer-size(16)>>)
    epochs = Tables.epochs()

    # append-only: old epoch retained, new epoch present
    assert epochs == %{0 => {:genesis, 0}, 1 => {:rotated_from, 0, 7}}
  end

  @tag :l38
  test "stale/regressing epoch is refused as a typed error, table untouched" do
    Tables.boot(
      frame_types: %{0 => {Frame, :handle_data}, 1 => {Frame, :handle_control}, 2 => {Frame, :handle_eos}},
      epochs: %{0 => {:genesis, 0}, 2 => {:rotated_from, 0, 3}}
    )

    frame = rotate_frame(2, 1)
    assert {:error, {:epoch_regression, 1, 2}} = Frame.handle_epoch_rotate(frame, <<1, 1::16>>)
    assert Tables.epochs() == %{0 => {:genesis, 0}, 2 => {:rotated_from, 0, 3}}
  end

  @tag :l38
  test "rotate to an existing epoch id is a regression (append-only law)" do
    Tables.boot(
      frame_types: %{0 => {Frame, :handle_data}, 1 => {Frame, :handle_control}, 2 => {Frame, :handle_eos}},
      epochs: %{0 => {:genesis, 0}, 1 => {:rotated_from, 0, 1}}
    )

    frame = rotate_frame(1, 1)
    assert {:error, {:epoch_regression, 1, 1}} = Frame.handle_epoch_rotate(frame, <<1, 1::16>>)
    assert Tables.epochs() == %{0 => {:genesis, 0}, 1 => {:rotated_from, 0, 1}}
  end

  @tag :l38
  test "pre-boot rotate is a typed refusal, seal absent" do
    # Unseal: restore the pre-boot world by dropping the seal key only.
    :persistent_term.erase({:aoq, :sealed})
    assert Tables.sealed?() == false

    frame = %Frame{epoch: 0, key_id: 0, frame_ordinal: 0, seq: 1}
    assert {:error, :tables_unbooted} = Frame.handle_epoch_rotate(frame, <<1, 1::16>>)
    assert Tables.epochs() == %{}
  end

  @tag :l38
  test "malformed rotate body (not prefix + exactly 2 bytes) is a typed refusal" do
    Tables.boot(
      frame_types: %{0 => {Frame, :handle_data}, 1 => {Frame, :handle_control}, 2 => {Frame, :handle_eos}},
      epochs: %{0 => {:genesis, 0}}
    )

    frame = %Frame{epoch: 0, key_id: 0, frame_ordinal: 0, seq: 1}
    # body too short: prefix + 1 byte only
    assert {:error, {:bad_rotate_payload, <<1, 5>>}} = Frame.handle_epoch_rotate(frame, <<1, 5>>)

    # unknown stream prefix (5) — not control
    assert {:error, {:bad_rotate_payload, <<5, 0, 1>>}} =
             Frame.handle_epoch_rotate(frame, <<5, 0, 1>>)

    # wrong stream prefix (data, not control)
    assert {:error, {:bad_rotate_payload, <<0, 0, 1>>}} =
             Frame.handle_epoch_rotate(frame, <<0, 0, 1>>)

    assert Tables.epochs() == %{0 => {:genesis, 0}}
  end
end
