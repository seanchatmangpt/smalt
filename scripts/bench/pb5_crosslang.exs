# PB-5 — cross-language differential bench: Erlang smalt_fond_powl_runner
# vs Smalt.POWL2.Executor on identical settlement plans.
#
# Gates (measured only, no promotion executed):
#   A  reductions/step (orchestration, caller-side statistics(:reductions) delta)
#   B  wall/orchestration, n=200 each (p50/p95/p99)
#   C  receipt byte-identity: the same canonical ledger sealed through the
#      Erlang seal path (smalt_fond_seal:seal/1) and an independent Elixir
#      mirror of the documented algorithm; must match byte-exact or typed
#      divergence is recorded.
#
# Output: emits one staged JSON line per row to stdout; the bash driver
# (pb5_crosslang.sh) routes through scripts/bench/lib.sh bench_emit.

ids =
  for i <- 1..16 do
    String.to_atom("pb5_t#{String.pad_leading(Integer.to_string(i), 3, "0")}")
  end

defmodule PB5 do
  @moduledoc false

  # Canonical OCEL ledger for a linear settlement plan of k steps, matching
  # the Erlang runner's emit sequence (htn_decompose x k, step_executed x k,
  # powl_projected, ocel_finalized, sealed). Validated against the runner's
  # own receipt merkle in gate C.
  def canonical_ledger(k, ids) do
    decomp =
      for {id, i} <- Enum.with_index(ids, 1), do: {i, %{kind: :htn_decompose, seq: i, step: id}}

    exec =
      for {id, i} <- Enum.with_index(ids, 1),
          do: {k + i, %{kind: :step_executed, seq: k + i, step: id}}

    pipeline = [
      {2 * k + 1, %{kind: :powl_projected, seq: 2 * k + 1, order: ids}},
      {2 * k + 2, %{kind: :ocel_finalized, seq: 2 * k + 2}},
      {2 * k + 3, %{kind: :sealed, seq: 2 * k + 3}}
    ]

    Map.new(decomp ++ exec ++ pipeline)
  end

  # Independent Elixir mirror of the documented smalt_fond_seal algorithm:
  # leaf = sha256(deterministic term_to_binary(event)), inner = sha256(l++r),
  # odd leaf duplicated. Leaf order = REVERSED raw maps:fold order (the Erlang
  # leaves/1 accumulates [Leaf|Acc]); same order the pinned gate admits.)
  def seal_mirror(ledger) when is_map(ledger) do
    ledger
    |> Map.keys()
    |> Enum.reverse()
    |> Enum.map(fn key -> :crypto.hash(:sha256, :erlang.term_to_binary(ledger[key], [:deterministic])) end)
    |> merkle()
    |> case do
      [] -> :crypto.hash(:sha256, "smalt-fond-empty-ledger")
      [root] -> root
      other -> other
    end
  end

  defp merkle([]), do: []
  defp merkle([leaf]), do: [leaf]
  defp merkle(leaves), do: merkle(pair(leaves))

  defp pair([a, b | t]), do: [:crypto.hash(:sha256, a <> b) | pair(t)]
  defp pair([a]), do: [:crypto.hash(:sha256, a <> a)]
  defp pair([]), do: []

  # --- engines -----------------------------------------------------------

  def run_erlang(ids) do
    r0 = elem(:erlang.statistics(:reductions), 0)
    t0 = System.monotonic_time(:microsecond)

    case :smalt_fond_powl_runner.run(%{tasks: ids}) do
      {:ok, receipt} ->
        t1 = System.monotonic_time(:microsecond)
        r1 = elem(:erlang.statistics(:reductions), 0)
        {:ok, receipt, t1 - t0, r1 - r0}

      {:crash, reason} ->
        t1 = System.monotonic_time(:microsecond)
        {:crash, reason, t1 - t0, nil}
    end
  end

  def run_elixir(ids) do
    k = length(ids)

    children =
      Map.new(Enum.with_index(ids, 1), fn {id, i} ->
        {id,
         %Smalt.POWL2.Reticle.AST.Transition{
           id: id,
           label: Atom.to_string(id),
           op: fn ctx -> {:ok, Map.put(ctx, id, i)} end
         }}
      end)

    order = for [a, b] <- Enum.chunk_every(ids, 2, 1, :discard), do: {a, b}

    model = %Smalt.POWL2.Reticle.AST.PartialOrder{children: children, order: order}

    r0 = elem(:erlang.statistics(:reductions), 0)
    t0 = System.monotonic_time(:microsecond)

    :ok =
      Smalt.POWL2.Executor.execute_admitted(
        :pb5,
        {:ok, model},
        %{},
        nil,
        self(),
        Smalt.POWL2.Reticle
      )

    receive do
      {:orchestration_completed, :pb5, _ctx, receipt} ->
        t1 = System.monotonic_time(:microsecond)
        r1 = elem(:erlang.statistics(:reductions), 0)
        {:ok, receipt, t1 - t0, r1 - r0}
    after
      30_000 -> exit(:pb5_executor_timeout)
    end
  end
end

# ---------------------------------------------------------------------------

# warmup
{status, _, _, _} = PB5.run_erlang(ids)
{status2, _, _, _} = PB5.run_elixir(ids)

n = 200

erlang_runs =
  for _ <- 1..n do
    PB5.run_erlang(ids)
  end

elixir_runs =
  for _ <- 1..n do
    PB5.run_elixir(ids)
  end

erl_ok_runs = Enum.filter(erlang_runs, fn {st, _, _, _} -> st == :ok end)
ex_ok_runs = Enum.filter(elixir_runs, fn {st, _, _, _} -> st == :ok end)
erl_errors = n - length(erl_ok_runs)
ex_errors = n - length(ex_ok_runs)
erl_receipt0 = erl_ok_runs |> hd() |> elem(1)
ex_receipt0 = ex_ok_runs |> hd() |> elem(1)

erl_walls = Enum.map(erl_ok_runs, fn {_, _, w, _} -> w end)
erl_reds = Enum.map(erl_ok_runs, fn {_, _, _, r} -> r end)
ex_walls = Enum.map(ex_ok_runs, fn {_, _, w, _} -> w end)
ex_reds = Enum.map(ex_ok_runs, fn {_, _, _, r} -> r end)

median = fn xs ->
  s = Enum.sort(xs)
  Enum.at(s, div(length(s), 2))
end

fmt = fn xs ->
  s = Enum.sort(xs)
  pct = fn p -> Enum.at(s, round(p / 100 * (length(s) - 1))) end
  "#{pct.(50)} #{pct.(95)} #{pct.(99)}"
end

erl_walls_ms = Enum.map(erl_walls, &(&1 / 1000.0))
ex_walls_ms = Enum.map(ex_walls, &(&1 / 1000.0))

# ---- gate C: receipt byte-identity -----------------------------------------

ledger = PB5.canonical_ledger(16, ids)
mirror_digest = PB5.seal_mirror(ledger)
{:ok, erl_direct_digest} = :smalt_fond_seal.seal(ledger)

byte_identity =
  erl_receipt0.merkle == mirror_digest and mirror_digest == erl_direct_digest and
    erl_receipt0.event_count == map_size(ledger) and
    ex_receipt0.status == :completed and ex_receipt0.phi_lease_final == 16 and
    Enum.map(ex_receipt0.steps, & &1.node) == ids

IO.puts("PB5_RESULT event_count=#{erl_receipt0.event_count} ledger_size=#{map_size(ledger)}")
IO.puts("PB5_RESULT erl_merkle=#{Base.encode16(erl_receipt0.merkle)}")
IO.puts("PB5_RESULT mirror_digest=#{Base.encode16(mirror_digest)}")
IO.puts("PB5_RESULT erl_direct_digest=#{Base.encode16(erl_direct_digest)}")
IO.puts("PB5_RESULT runner_otp=#{erl_receipt0.otp_release}")
IO.puts(
  "PB5_RESULT byte_identity=#{byte_identity} " <>
    "steps_ex=#{length(ex_receipt0.steps)} phi=#{ex_receipt0.phi_lease_final} status=#{inspect(ex_receipt0.status)}"
)

IO.puts(
  "PB5_RESULT erl_errors=#{erl_errors} ex_errors=#{ex_errors} erl_runs=#{length(erl_ok_runs)} " <>
  "PB5_RESULT erl_wall_p509599=#{fmt.(erl_walls_ms)} erl_wall_median=#{median.(erl_walls_ms)} " <>
    "ex_wall_p509599=#{fmt.(ex_walls_ms)} ex_wall_median=#{median.(ex_walls_ms)}"
)

IO.puts(
  "PB5_RESULT erl_reds_per_step=#{Float.round(median.(erl_reds) / 16, 2)} " <>
    "ex_reds_per_step=#{Float.round(median.(ex_reds) / 16, 2)} " <>
    "erl_reds_median=#{median.(erl_reds)} ex_reds_median=#{median.(ex_reds)}"
)

erl_ops = n / (Enum.sum(erl_walls_ms) / 1000)
ex_ops = n / (Enum.sum(ex_walls_ms) / 1000)

IO.puts("PB5_ROWS_BEGIN")
IO.puts("erlang_runner|settlement_orchestration|#{n}|#{Float.round(erl_ops, 1)}|#{fmt.(erl_walls_ms)}|#{erl_errors}")
IO.puts("powl2_executor|settlement_orchestration|#{n}|#{Float.round(ex_ops, 1)}|#{fmt.(ex_walls_ms)}|#{ex_errors}")
IO.puts("PB5_ROWS_END")

# dump raw latencies for the bash driver's percentile cross-check
IO.puts("PB5_ERL_WALLS #{Enum.join(erl_walls_ms, ",")}")
IO.puts("PB5_EX_WALLS #{Enum.join(ex_walls_ms, ",")}")
