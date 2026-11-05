defmodule Smalt.Aoq.CursorTest do
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Cursor

  @mod 18_446_744_073_709_551_616

  test "new/0 zeroes all six slots" do
    c = Cursor.new()

    assert Cursor.head(c) == 0
    assert Cursor.tail(c) == 0
    assert Cursor.in_flight(c) == 0
    assert Cursor.drops(c) == 0
  end

  test "claim_head/release_tail advance and return claimed slot indices" do
    c = Cursor.new()

    assert Cursor.claim_head(c) == 0
    assert Cursor.claim_head(c) == 1
    assert Cursor.head(c) == 2

    assert Cursor.release_tail(c) == 0
    assert Cursor.release_tail(c) == 1
    assert Cursor.tail(c) == 2
    assert Cursor.in_flight(c) == 0
  end

  test "batch claim/release return the first slot of the batch" do
    c = Cursor.new()

    first = Cursor.claim_head(c, 4)
    assert first == 0
    assert Cursor.head(c) == 4

    first = Cursor.release_tail(c, 4)
    assert first == 0
    assert Cursor.tail(c) == 4
  end

  test "concurrent claimers get disjoint slots (add_get is the CAS)" do
    c = Cursor.new()
    n = 20

    results =
      Task.async_stream(1..n, fn _ -> Cursor.claim_head(c) end,
        max_concurrency: n,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, slot} -> slot end)

    assert Enum.sort(results) == Enum.to_list(0..(n - 1))
    assert Cursor.head(c) == n
    assert Enum.sum(results) == div(n * (n - 1), 2)
  end

  test "leases are (gen, ctr); reset bumps gen and invalidates outstanding leases" do
    c = Cursor.new()

    {gen0, ctr0} = Cursor.lease_acquire(c)
    assert gen0 == 0
    assert ctr0 == 1
    assert Cursor.lease_valid?(c, {gen0, ctr0})

    {_gen1, ctr1} = Cursor.lease_acquire(c)
    assert ctr1 == 2

    Cursor.reset(c)
    new_gen = Cursor.lease_acquire(c) |> elem(0)
    assert new_gen == 1
    refute Cursor.lease_valid?(c, {gen0, ctr0})
    assert Cursor.lease_valid?(c, {new_gen, ctr0 + 100})
  end

  test "seq_next is a monotone wrapping counter" do
    c = Cursor.new()

    assert [Cursor.seq_next(c), Cursor.seq_next(c), Cursor.seq_next(c)] == [1, 2, 3]
  end

  test "seq_before? is wrap-safe across the u64 boundary" do
    # near-boundary values: b is 1 after a, no wrap
    a = 18_446_744_073_709_551_614
    b = rem(a + 1, @mod)
    assert Cursor.seq_before?(a, b)
    refute Cursor.seq_before?(b, a)

    # small values vs near-max: small is "after" in wrap order
    assert Cursor.seq_before?(18_446_744_073_709_551_615, 0)
    assert Cursor.seq_before?(18_446_744_073_709_551_615, 5)
    refute Cursor.seq_before?(5, 18_446_744_073_709_551_615)

    # half-mod boundary: exactly 2^63 ahead is not "before" (ambiguous half)
    refute Cursor.seq_before?(0, 9_223_372_036_854_775_808)
    assert Cursor.seq_before?(0, 9_223_372_036_854_775_807)

    # equal is not before
    refute Cursor.seq_before?(7, 7)

    # naive < would invert these
    refute Cursor.seq_before?(0, 18_446_744_073_709_551_615)
  end

  test "seq_distance is (b - a) mod 2^64" do
    assert Cursor.seq_distance(3, 10) == 7
    assert Cursor.seq_distance(10, 3) == @mod - 7
    assert Cursor.seq_distance(18_446_744_073_709_551_615, 0) == 1
  end

  test "drop counters accumulate" do
    c = Cursor.new()

    Cursor.drop(c)
    Cursor.drop(c, 3)
    assert Cursor.drops(c) == 4
    assert Cursor.drop(c, 2) == 6
  end
end
