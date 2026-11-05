defmodule Smalt.Aoq.Scheduler do
  @moduledoc """
  AoQ scheduler-pinning helper (LANE-09, AoQ program brief §4).

  **Law**: AoQ handler processes pin to a scheduler core; everything else
  floats across all schedulers as the runtime schedules it.

  Pair this with the release VM flags `+sbt db` + `+sbwt none`
  (`rel/vm.args.eex`): pinned handlers keep their core; the no-busy-wait
  flag keeps unpinned work from spinning on cores reserved for handlers.
  """

  @doc """
  Pin the calling process to scheduler id `core`.

  Wraps `:erlang.process_flag(:scheduler, core)`. `core` must be within
  `1..schedulers_online`; the runtime raises `badarg` otherwise.

  Returns the previous binding: `0` if the process was not pinned, otherwise
  the scheduler id it was pinned to (witnessed on OTP 29: first pin in a
  fresh process returns 0, re-pin returns the prior id).
  """
  @spec pin(pos_integer()) :: non_neg_integer()
  def pin(core) when is_integer(core) and core >= 1 do
    :erlang.process_flag(:scheduler, core)
  end

  @doc """
  Bounded round-robin core allocation: returns the next core in
  `1..:erlang.system_info(:schedulers_online)`, wrapping around.

  Backed by a persistent `:atomics` counter — safe under concurrency.
  """
  @spec next_core() :: pos_integer()
  def next_core do
    schedulers = :erlang.system_info(:schedulers_online)
    n = :atomics.add_get(counter_ref(), 1, 1)
    rem(n - 1, schedulers) + 1
  end

  # One persistent, persistent-term-cached atomics counter per VM.
  # :persistent_term.get with a default is atomic and race-free: the first
  # caller creates the counter, every later caller reuses it.
  defp counter_ref do
    case :persistent_term.get({__MODULE__, :counter}, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put({__MODULE__, :counter}, ref)
        ref

      ref ->
        ref
    end
  end
end
