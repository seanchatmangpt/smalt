defmodule Smalt.Powl2.GraphCompat do
  @moduledoc """
  AR-POWL-03 adoption seam for the OTP 29 stdlib-8.1 immutable `:graph`
  module (confirmed on 29.1.1: `new/0`, `add_vertex/2`, `add_edge/3`,
  `is_acyclic/1`, `topsort/1`, `condensation/1`; ABSENT on OTP 28).

  `acyclic?/1` dispatches on engine: native `:graph` when the `:graph`
  module is loaded with `is_acyclic/1` exported (OTP 29+), else a
  pure-Elixir seen-set DFS (same discipline as the reticle cycle check:
  terminates on cyclic input by exhaustion of the vertex set, never a
  clock). Both engines implement one law: a directed cycle — including a
  self-loop — makes `acyclic?` false.
  """

  @type vertex :: term()
  @type edge :: {vertex(), vertex()}

  @doc """
  Which cycle engine is live: `:native` (OTP 29 `:graph`) or `:elixir`
  (fallback DFS). Computed per call — no compile-time pin, so the same
  beam reports honestly on both OTP releases.
  """
  @spec engine() :: :native | :elixir
  def engine do
    if Code.ensure_loaded?(:graph) and function_exported?(:graph, :is_acyclic, 1) do
      :native
    else
      :elixir
    end
  end

  @doc """
  True iff the directed graph given as `{from, to}` edge pairs is
  acyclic. Empty edge list is trivially acyclic. Self-loops are cycles.
  """
  @spec acyclic?([edge()]) :: boolean()
  def acyclic?(edges) when is_list(edges) do
    if engine() == :native do
      native_acyclic?(edges)
    else
      elixir_acyclic?(edges)
    end
  end

  @doc """
  The native OTP 29 leg, callable directly for cross-engine courts.
  Refuses with `{:error, :native_graph_unavailable}` when `:graph` is
  absent (OTP 28) — never a silent fallback.
  """
  @spec native_acyclic?([edge()]) :: boolean() | {:error, :native_graph_unavailable}
  def native_acyclic?(edges) do
    if engine() == :native do
      do_native_acyclic?(edges)
    else
      {:error, :native_graph_unavailable}
    end
  end

  # Elixir 1.20 forbids text after the heredoc opener (TOOLUP unblock 2026-10-21)
  @doc """
  The pure-Elixir fallback leg, callable directly for cross-engine courts.
  """
  @spec elixir_acyclic?([edge()]) :: boolean()
  def elixir_acyclic?(edges) do
    adj = Enum.reduce(edges, %{}, fn {x, y}, acc -> Map.update(acc, x, [y], &[y | &1]) end)
    do_acyclic?(Map.keys(adj), adj, MapSet.new())
  end

  # -- native leg (OTP 29 :graph) ------------------------------------------------

  # Dynamic dispatch (apply/3): `:graph` exists only on OTP 29+ stdlib, and
  # compiling on an OTP 28 toolchain would otherwise emit undefined-module
  # warnings. Runtime availability is guarded in engine/0 via
  # Code.ensure_loaded?/1 — this leg only runs when :graph is loaded.
  defp do_native_acyclic?(edges) do
    g0 = apply(:graph, :new, [])

    g1 =
      Enum.reduce(edges, g0, fn {x, y}, acc ->
        acc = apply(:graph, :add_vertex, [acc, x])
        acc = apply(:graph, :add_vertex, [acc, y])
        apply(:graph, :add_edge, [acc, x, y])
      end)

    apply(:graph, :is_acyclic, [g1])
  end

  # -- fallback leg (pure Elixir, OTP 28-safe) ------------------------------------

  # Per-root DFS with a done-set: each root expanded at most once, so the
  # check terminates on cyclic input by exhaustion of the vertex set,
  # never a clock. Same seen-set discipline as the reticle cycle check.
  defp do_acyclic?([], _adj, _done), do: true

  defp do_acyclic?([v | rest], adj, done) do
    if MapSet.member?(done, v) do
      do_acyclic?(rest, adj, done)
    else
      case dfs(v, adj, [v], done) do
        {:cycle, _} -> false
        {:ok, done2} -> do_acyclic?(rest, adj, done2)
      end
    end
  end

  defp dfs(v, adj, path, done) do
    ns = Map.get(adj, v, [])

    walk(ns, adj, path, done)
  end

  defp walk([], _adj, _path, done), do: {:ok, done}

  defp walk([n | ns], adj, path, done) do
    cond do
      n in path ->
        {:cycle, n}

      MapSet.member?(done, n) ->
        walk(ns, adj, path, done)

      true ->
        case dfs(n, adj, [n | path], done) do
          {:ok, done2} -> walk(ns, adj, path, done2)
          cyc -> cyc
        end
    end
  end
end
