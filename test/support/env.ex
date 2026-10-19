defmodule SmaltTest.Env do
  @moduledoc """
  Canonical Application-env save/restore (v26.10.18). Replaces the
  process-dictionary `:prev_*` pattern and the hand-rolled on_exit restores
  (leak-batch1..5 campaign). Restore discipline is load-bearing: put when
  the previous value was non-nil, delete_env when it was unset — never the
  reverse (leak-batch1 finding 2: `delete_env` on a pre-existing value
  destroys sibling-visible config).
  """

  @unset :__unset__

  @doc """
  Scoped mutation: saves prev, runs `fun`, restores in an `after` (exception-
  and flunk-safe). `kvs` is a keyword list of {key, new_value}.
  """
  @spec with(keyword, (-> term)) :: term
  def with(kvs, fun) when is_list(kvs) and is_function(fun, 0) do
    SmaltTest.IsolationFormatter.sync()

    prev = Enum.map(kvs, fn {k, _} -> {k, Application.get_env(:smalt, k, @unset)} end)

    Enum.each(kvs, fn {k, v} -> Application.put_env(:smalt, k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn
        {k, @unset} -> Application.delete_env(:smalt, k)
        {k, v} -> Application.put_env(:smalt, k, v)
      end)
    end
  end

  @doc """
  Setup-form: mutates env and registers the restore via on_exit. Use inside
  `setup` when the mutation must outlive setup (whole-test scoping).
  """
  @spec put_restored(keyword) :: :ok
  def put_restored(kvs) when is_list(kvs) do
    # Baseline barrier (i29): ExUnit delivers formatter events as casts, so
    # the twin's baseline snapshot can race this very setup. Block until the
    # formatter has processed the case's `case_started` before mutating env.
    SmaltTest.IsolationFormatter.sync()

    prev = Enum.map(kvs, fn {k, _} -> {k, Application.get_env(:smalt, k, @unset)} end)

    Enum.each(kvs, fn {k, v} -> Application.put_env(:smalt, k, v) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(prev, fn
        {k, @unset} -> Application.delete_env(:smalt, k)
        {k, v} -> Application.put_env(:smalt, k, v)
      end)
    end)

    :ok
  end
end
