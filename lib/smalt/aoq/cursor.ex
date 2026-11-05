defmodule Smalt.Aoq.Cursor do
  @moduledoc """
  AOQ ring cursor: one `:atomics` array per ring with a fixed u64 slot
  layout (spec §6, `docs/jira/v26.11.5/aq-architecture-spec.md`).

  ## Slot layout (u64, indices fixed)

  | index | name        | meaning |
  |---|---|---|
  | 0 | `ring_head` | write cursor: next slot a producer claims |
  | 1 | `ring_tail` | read cursor: next slot a consumer releases |
  | 2 | `lease_ctr` | monotone lease counter for slot leases |
  | 3 | `lease_gen` | lease generation (bumped on ring reset) |
  | 4 | `seq`       | u64 wrapping sequence number for frame ordering |
  | 5 | `drop_ctr`  | cumulative drops, off the GenServer hot path |

  ## Concurrency law

  Ring cursors advance with `:atomics.add_get` — the CAS-equivalent
  claim (`add_get(head, +1)`) and release (`add_get(tail, +1)`).
  Capacity bounds are enforced by the head−tail distance, not by a
  check-then-set on a counter.

  **Single-writer-per-index**: every index has exactly one mutating op
  class (`add_get`), so no compare-exchange loop is needed anywhere in
  this module. Producers claim head slots; consumers release tail;
  `lease_ctr` and `seq` are add-only; `lease_gen` is bumped only by
  `reset/1` (ring reset); `drop_ctr` is add-only.

  All reads are plain `:atomics.get` — no lock exists in the layout.
  The atomics array is ref-counted off-heap memory, immune to owner
  death; recreating via `Cursor` restart only re-establishes the
  handle. The data semantics are carried by the slot layout above.

  Wrapping is lawful: u64 wraps are accepted and all ordering
  comparisons are subtraction-based wrap-safe compares
  (`(a - b) mod 2^64 < 2^63`) — never `a < b`, which would invert every
  comparison after 2^64 frames.
  """

  @half 9_223_372_036_854_775_808
  @mod 18_446_744_073_709_551_616

  @off 1
  @head 0
  @tail 1
  @lease_ctr 2
  @lease_gen 3
  @seq 4
  @drop_ctr 5

  @type t :: :atomics.ref()

  @doc """
  Creates the cursor array (all counters start at 0).

  Erlang `:atomics` indices are 1-based while the spec layout is
  0-based, so the array is allocated with 7 slots and every access
  maps spec slot `i` to atomics index `i + 1`. The observable layout
  (slot numbers, ordering, semantics) is exactly the spec table.
  """
  @spec new() :: t()
  def new do
    :atomics.new(7, signed: false)
  end

  @doc """
  Claims the next head slot: `add_get(ring_head, 1)`. Returns the
  claimed slot index (the pre-advance value of `ring_head`).
  """
  @spec claim_head(t()) :: non_neg_integer()
  def claim_head(cursor) do
    :atomics.add_get(cursor, @head + @off, 1) - 1
  end

  @doc """
  Releases the next tail slot: `add_get(ring_tail, 1)`. Returns the
  released slot index (the pre-advance value of `ring_tail`).
  """
  @spec release_tail(t()) :: non_neg_integer()
  def release_tail(cursor) do
    :atomics.add_get(cursor, @tail + @off, 1) - 1
  end

  @doc "Claims a batch of `n` head slots; returns the first claimed slot."
  @spec claim_head(t(), pos_integer()) :: non_neg_integer()
  def claim_head(cursor, n) when is_integer(n) and n > 0 do
    :atomics.add_get(cursor, @head + @off, n) - n
  end

  @doc "Releases a batch of `n` tail slots; returns the first released slot."
  @spec release_tail(t(), pos_integer()) :: non_neg_integer()
  def release_tail(cursor, n) when is_integer(n) and n > 0 do
    :atomics.add_get(cursor, @tail + @off, n) - n
  end

  @doc "Current `ring_head`."
  @spec head(t()) :: non_neg_integer()
  def head(cursor), do: :atomics.get(cursor, @head + @off)

  @doc "Current `ring_tail`."
  @spec tail(t()) :: non_neg_integer()
  def tail(cursor), do: :atomics.get(cursor, @tail + @off)

  @doc "In-flight distance `ring_head - ring_tail` (the capacity bound signal)."
  @spec in_flight(t()) :: non_neg_integer()
  def in_flight(cursor), do: head(cursor) - tail(cursor)

  @doc """
  Acquires a lease: `add_get(lease_ctr, 1)`. Returns `{gen, ctr}`.
  The lease is valid only while `lease_gen` still equals `gen`.
  """
  @spec lease_acquire(t()) :: {non_neg_integer(), non_neg_integer()}
  def lease_acquire(cursor) do
    {:atomics.get(cursor, @lease_gen + @off), :atomics.add_get(cursor, @lease_ctr + @off, 1)}
  end

  @doc "True when the lease `{gen, ctr}` is still valid (generation unchanged)."
  @spec lease_valid?(t(), {non_neg_integer(), non_neg_integer()}) :: boolean()
  def lease_valid?(cursor, {gen, _ctr}) do
    :atomics.get(cursor, @lease_gen + @off) == gen
  end

  @doc """
  Ring reset: bumps `lease_gen`, invalidating all outstanding leases
  without resetting `lease_ctr` — late lease holders fail typed.
  """
  @spec reset(t()) :: non_neg_integer()
  def reset(cursor) do
    :atomics.add_get(cursor, @lease_gen + @off, 1)
  end

  @doc """
  Next wrapping sequence number: `add_get(seq, 1)`. Returns the u64
  seq (wraps past 18446744073709551615).
  """
  @spec seq_next(t()) :: non_neg_integer()
  def seq_next(cursor) do
    :atomics.add_get(cursor, @seq + @off, 1)
  end

  @doc """
  Wrap-safe ordering: returns `true` iff `b` is strictly after `a` in
  u64 wrap order — i.e. the signed-wrapped distance
  `(b - a) mod 2^64` is nonzero and less than `2^63`. Never compares
  `a < b` directly, which would invert every ordering after 2^64
  frames. Equal values are not "before".
  """
  @spec seq_before?(non_neg_integer(), non_neg_integer()) :: boolean()
  def seq_before?(a, b) do
    d = Integer.mod(b - a, @mod)
    d != 0 and d < @half
  end

  @doc "Wrap-safe distance `(b - a) mod 2^64`."
  @spec seq_distance(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def seq_distance(a, b) do
    Integer.mod(b - a, @mod)
  end

  @doc "Cumulative drop count."
  @spec drops(t()) :: non_neg_integer()
  def drops(cursor), do: :atomics.get(cursor, @drop_ctr + @off)

  @doc "Records `n` drops: `add_get(drop_ctr, n)`."
  @spec drop(t(), pos_integer()) :: non_neg_integer()
  def drop(cursor, n \\ 1) do
    :atomics.add_get(cursor, @drop_ctr + @off, n)
  end

  @doc """
  Point-in-time durable snapshot of the cursor counters (`head`, `tail`,
  `seq`, `lease_gen`, `drop_ctr`) — the payload `CursorPersist` folds into
  a journal checkpoint frame. Reads are individually atomic; the snapshot
  is a safe upper-bound read (a concurrent producer can advance `head`
  during the read; `CursorPersist` only ever checkpoints `tail` progress,
  which is monotone).
  """
  @spec durable_snapshot(t()) :: %{
          required(:head) => non_neg_integer(),
          required(:tail) => non_neg_integer(),
          required(:seq) => non_neg_integer(),
          required(:lease_gen) => non_neg_integer(),
          required(:drop_ctr) => non_neg_integer()
        }
  def durable_snapshot(cursor) do
    %{
      head: head(cursor),
      tail: tail(cursor),
      seq: :atomics.get(cursor, @seq + @off),
      lease_gen: :atomics.get(cursor, @lease_gen + @off),
      drop_ctr: drops(cursor)
    }
  end

  @doc """
  Boot-only restore of a durable snapshot into a FRESH cursor.

  Law: the target cursor must be virgin — `tail == 0` or the restore
  raises (`:restore_tail_nonzero`): restoring over live consumers would
  silently rewind or fork the ring. `head` that LAGS the durable `tail`
  (a snapshot taken mid-advance, head read before tail progressed) is
  RAISED to the durable tail — head >= tail is the ring invariant, and
  a head behind the restored tail would let producers claim already-
  released slots. Beyond that the snapshot's head/seq/drop counters are
  adopted verbatim (durable maxima; producers only advance them).
  """
  @spec restore_from_durable(t(), map()) :: :ok
  def restore_from_durable(cursor, %{tail: tail} = snap) do
    if tail(cursor) != 0 do
      raise ArgumentError, ":restore_tail_nonzero — restore_from_durable/2 is boot-only"
    end

    head = max(snap[:head] || 0, tail)
    :atomics.put(cursor, @head + @off, head)
    :atomics.put(cursor, @tail + @off, tail)
    :atomics.put(cursor, @seq + @off, snap[:seq] || 0)
    :atomics.put(cursor, @drop_ctr + @off, snap[:drop_ctr] || 0)

    :ok
  end

  def restore_from_durable(_cursor, snap) do
    raise ArgumentError, ":bad_durable_snapshot — #{inspect(snap)}"
  end
end
