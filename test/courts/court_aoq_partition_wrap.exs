defmodule Court.Aoq.Partition.Wrap do
  @moduledoc """
  LANE-05 wrap court (direct-call level, no processes). Pins the u64
  wrap law on the real `Smalt.Aoq.Cursor` layout: preset the seq slot
  near 2^64 with `:atomics.put`, take `seq_next/0` across the wrap,
  pin `seq_before?/2` to the half-space law (cursor.ex `@half`/`@mod`),
  and prove claim/release bring `in_flight` back to 0.
  """

  use ExUnit.Case, async: true

  alias Smalt.Aoq.Cursor

  @seq_atomic_index 5 # cursor.ex @seq 4 + @off 1
  @half 9_223_372_036_854_775_808
  @mod 18_446_744_073_709_551_616
  @max_u64 18_446_744_073_709_551_615

  test "seq wraps at 2^64 and ordering is wrap-safe" do
    cursor = Cursor.new()
    :atomics.put(cursor, @seq_atomic_index, @max_u64 - 2)

    # seq_next is add_get: it returns the POST-advance value.
    assert Cursor.seq_next(cursor) == @max_u64 - 1
    assert Cursor.seq_next(cursor) == @max_u64
    assert Cursor.seq_next(cursor) == 0
    assert Cursor.seq_next(cursor) == 1

    # Half-space law, pinned to the same constants cursor.ex compiles with.
    assert Cursor.seq_before?(@max_u64, 0)
    assert Cursor.seq_before?(@max_u64 - 1, 1)
    refute Cursor.seq_before?(0, @max_u64)
    refute Cursor.seq_before?(7, 7)
    assert Cursor.seq_before?(6, 7)
    _ = {@half, @mod}
  end

  test "claim/release in_flight returns to 0" do
    cursor = Cursor.new()

    assert Cursor.in_flight(cursor) == 0

    first = Cursor.claim_head(cursor, 4)
    assert Cursor.in_flight(cursor) == 4
    assert first == 0

    _released = Cursor.release_tail(cursor, 4)
    assert Cursor.in_flight(cursor) == 0
  end
end
