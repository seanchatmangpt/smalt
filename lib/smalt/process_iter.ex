defmodule Smalt.ProcessIter do
  @moduledoc """
  Heap-bounded whole-VM process traversal (AR-CORE-01 / IMPL-1).

  Uses the OTP 29 iterator BIFs (`:erlang.processes_iterator/0` +
  `:erlang.processes_next/1`) so the caller never materializes the full
  pid list; on pre-29 toolchains it falls back to `:erlang.processes/0`
  and reports the fallback via `mode/0`, never silently.

  Return of `next/1`:
    * `{pid, iterator}` — keep walking
    * `:none` — done
  """

  @doc "Current traversal mode: `:iterator` or `:fallback_full_list`."
  @spec mode() :: :iterator | :fallback_full_list
  def mode do
    if function_exported?(:erlang, :processes_iterator, 0), do: :iterator, else: :fallback_full_list
  end

  @doc "Fresh iterator over all processes in the VM."
  @spec iterator() :: term()
  def iterator do
    if mode() == :iterator do
      :erlang.processes_iterator()
    else
      :erlang.processes()
    end
  end

  @doc """
  Advance one step. `iterator/0` returns either the real OTP 29 iterator
  or (pre-29 fallback) the full pid list; `next/1` normalizes both to
  `{pid, rest}` / `:none` so callers are mode-agnostic.
  """
  @spec next(term()) :: {pid, term()} | :none
  def next(iterator_or_list)

  def next([first | rest]) do
    {first, rest}
  end

  def next([]), do: :none

  def next(iter) do
    case :erlang.processes_next(iter) do
      {pid, next_iter} -> {pid, next_iter}
      :none -> :none
    end
  end

  @doc """
  Reduce over every process in the VM. `acc_fun(pid, acc) -> acc`.
  Never materializes the pid list in `:iterator` mode.
  """
  @spec reduce(acc :: term(), (pid, term() -> term()), keyword()) :: term()
  def reduce(acc, acc_fun, _opts \\ []) when is_function(acc_fun, 2) do
    do_reduce(iterator(), acc, acc_fun)
  end

  defp do_reduce(iter, acc, fun) do
    case next(iter) do
      {pid, rest} -> do_reduce(rest, fun.(pid, acc), fun)
      :none -> acc
    end
  end

  @doc "Count of processes traversed, one step at a time."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    reduce(0, fn _pid, n -> n + 1 end, opts)
  end

  @doc "Caller heap size in words, GC'd immediately before the read."
  @doc since: "0.1.0"
  @spec caller_heap_words() :: non_neg_integer()
  def caller_heap_words do
    :erlang.garbage_collect()
    {:heap_size, heap_size} = :erlang.process_info(self(), :heap_size)
    heap_size
  end
end
