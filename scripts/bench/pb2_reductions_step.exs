# PB-2: reductions-per-workflow-step denominator (menu item 2).
#
# One settlement orchestration = HTN→FOND→POWL→OCEL→seal over an 8-task plan.
# Per-stage reductions via :erlang.statistics(:reductions) delta (process-local,
# so every stage body runs in *this* process), per-stage allocated words via
# tprof :call_memory (same pattern as scripts/tprof_memory_profile.exs).
#
# Stage bodies call the real modules:
#   htn_decompose      smalt_fond_plan:linear_plan/1 + assert_acyclic/1
#                      (exactly the runner's stage-1 work, runner L90-92)
#   fond_synthesize    smalt_fond_plan:next_ready/2 scheduling loop to
#                      completion (the runner's stage-2 scheduling work;
#                      the emit/2 ledger map-put mirror is measured inside
#                      the fond_runner_total row, not attributed per-stage)
#   graph_validation   Smalt.Powl2.GraphCompat.acyclic?/1 over the plan's
#                      needs-edges (native :graph leg on OTP 29)
#   execute_primitive  per executed step: next_ready + done-map update +
#                      ReceiptEngine.record_step (real provenance chain insert)
#   receipt_seal       ReceiptEngine.seal_receipt/3 over the recorded run
#   fond_runner_total  the whole real gen_statem pipeline
#                      smalt_fond_powl_runner:run/1 (its own process — this
#                      row measures wall-cost of the pipeline, its reductions
#                      are the caller-side cost of run/1, NOT the pipeline's;
#                      the per-stage rows are the honest denominator)
#
# Run (from repo root):
#   MIX_BUILD_ROOT=_build-pb2 mix run --no-start scripts/bench/pb2_reductions_step.exs
# with OTP 29.1.2 on PATH (asdf pin: .tool-versions erlang 29.1.2).

IO.puts("otp_release = #{:erlang.system_info(:otp_release)}")

root = List.to_string(:code.root_dir())

tp_bin =
  case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
    [bin | _] -> bin
    [] -> raise("tprof unavailable: no tools-*/ebin under " <> root)
  end

true = :code.add_path(String.to_charlist(tp_bin))

emit_dir = Path.expand("tmp/bench", File.cwd!())
File.mkdir_p!(emit_dir)
out = Path.join(emit_dir, "pb2-reductions-step.jsonl")

n_tasks = 8
iters = 200
warm = 20

machine = %{
  "otp" => to_string(:erlang.system_info(:otp_release)),
  "erts" => to_string(:erlang.system_info(:version)),
  "elixir" => System.version(),
  "jit" =>
    try do
      inspect(:erlang.system_info(:emu_flavor))
    rescue
      _ -> "unknown"
    end
}

IO.puts("machine = #{inspect(machine)}")

Code.ensure_loaded!(:smalt_fond_plan)
Code.ensure_loaded!(Smalt.Powl2.GraphCompat)
Code.ensure_loaded!(Smalt.PPlan.ReceiptEngine)

tasks = Enum.map(1..n_tasks, &:"settle_#{&1}")

# ---- stage bodies (each returns :ok, runs entirely in the calling process) ----

htn_body = fn ->
  plan = :smalt_fond_plan.linear_plan(tasks)
  :ok = :smalt_fond_plan.assert_acyclic(plan)
  true = length(:smalt_fond_plan.steps(plan)) == n_tasks
  :ok
end

# full scheduling loop: next_ready until none, marking done (stage-2 work)
fond_body = fn ->
  plan = :smalt_fond_plan.linear_plan(tasks)
  steps = :smalt_fond_plan.steps(plan)
  PB2.fond_loop(steps, %{})
  :ok
end

edges =
  Enum.flat_map(:smalt_fond_plan.steps(:smalt_fond_plan.linear_plan(tasks)), fn s ->
    Enum.map(s.needs, fn need -> {need, s.id} end)
  end)

graph_body = fn ->
  true = Smalt.Powl2.GraphCompat.acyclic?(edges)
  :ok
end

defmodule PB2 do
  # scheduling loop mirroring runner stage 2: repeatedly take the ready step
  # and mark it done until none remain.
  def fond_loop(steps, done) do
    case :smalt_fond_plan.next_ready(steps, done) do
      :none ->
        done

      step ->
        fond_loop(steps, Map.put(done, step.id, true))
    end
  end

  def with_run(run_id, fun) do
    path = Path.join(System.tmp_dir!(), "pb2-#{run_id}.dets")
    File.rm(path)
    {:ok, _} = Smalt.PPlan.ReceiptEngine.open(run_id, path)

    try do
      fun.()
    after
      :ok = Smalt.PPlan.ReceiptEngine.close(run_id)
      File.rm(path)
    end
  end

  # One full orchestration's provenance recording: one record_step per
  # executed FOND step (the execute_primitive work), then seal.
  def record_and_seal(run_id) do
    for i <- 1..8 do
      Smalt.PPlan.ReceiptEngine.record_step(run_id, %{
        epoch: 1,
        act: "execute_primitive:#{i}",
        delta: {:settle, i, :ok}
      })
    end

    rcpt = Smalt.PPlan.ReceiptEngine.seal_receipt(run_id, 1, nil)
    true = rcpt.step_count == 8
    :ok
  end

  def record_only(run_id) do
    for i <- 1..8 do
      Smalt.PPlan.ReceiptEngine.record_step(run_id, %{
        epoch: 1,
        act: "execute_primitive:#{i}",
        delta: {:settle, i, :ok}
      })
    end

    :ok
  end

  def seal_only(run_id) do
    rcpt = Smalt.PPlan.ReceiptEngine.seal_receipt(run_id, 1, nil)
    true = rcpt.step_count == 8
    :ok
  end
end

# ---- runner: reductions over iters repeats of a stage body -------------------

bench = fn name, body ->
  for _ <- 1..warm, do: body.()

  {r0, _} = :erlang.statistics(:reductions)
  t0 = System.monotonic_time(:millisecond)

  for _ <- 1..iters, do: body.()

  {r1, _} = :erlang.statistics(:reductions)
  ms = System.monotonic_time(:millisecond) - t0
  reds = div(r1 - r0, iters)
  IO.puts("#{name}: #{reds} reductions/txn, #{ms}ms total")
  {name, reds, ms}
end

htn = bench.("htn_decompose", htn_body)
fond = bench.("fond_synthesize", fond_body)
graph = bench.("graph_validation", graph_body)

# execute_primitive + seal ride a fresh DETS run per iteration
prim =
  bench.("execute_primitive_step", fn ->
    PB2.with_run("prim", fn -> PB2.record_only("prim") end)
  end)

seal =
  bench.("receipt_seal", fn ->
    PB2.with_run("seal", fn ->
      PB2.record_only("seal")
      PB2.seal_only("seal")
    end)
  end)

# seal cost alone (seal row minus record): measure record as part of prim,
# seal-alone = open steps + sort + merkle + ntriples over 8 steps
# seal cost over a pre-recorded run: record once, keep the DETS table open,
# then only seal_receipt inside the measured loop
seal_alone_path = Path.join(System.tmp_dir!(), "pb2-sealonly.dets")
File.rm(seal_alone_path)
{:ok, _} = Smalt.PPlan.ReceiptEngine.open("sealonly", seal_alone_path)
PB2.record_only("sealonly")

seal_alone =
  bench.("receipt_seal_alone", fn ->
    PB2.seal_only("sealonly")
  end)

:ok = Smalt.PPlan.ReceiptEngine.close("sealonly")
File.rm(seal_alone_path)

# whole real gen_statem pipeline (cross-check row; see header comment)
run_one = fn ->
  {:ok, pid} = :smalt_fond_powl_runner.start_pipeline(%{tasks: tasks})
  m = :erlang.monitor(:process, pid)

  result =
    receive do
      # completion protocol moved under me mid-session (lane edit of the
      # runner): newer form exits {:completed, Receipt}; older form sends
      # pipeline_complete. Accept both.
      {:DOWN, ^m, :process, ^pid, {:completed, r}} -> {:ok, r}
      {:pipeline_complete, r} -> {:ok, r}
      {:DOWN, ^m, :process, ^pid, reason} -> raise "runner crash: #{inspect(reason)}"
    end

  :erlang.demonitor(m, [:flush])
  result
end

runner_total =
  bench.("fond_runner_total", fn ->
    {:ok, r} = run_one.()
    true = r.step_count == n_tasks
    :ok
  end)

# ---- tprof call_memory: words per stage (single profiled call per stage) ------

words_for = fn name, body ->
  {:ok, {:call_memory, results}} = :tprof.profile(body, %{type: :call_memory, report: :return})
  words = Enum.sum(Enum.map(results, fn {_m, _f, alloc, _args} -> alloc end))
  IO.puts("#{name}: #{words} words")
  {name, words}
end

w_htn = words_for.("htn_decompose", htn_body)
w_fond = words_for.("fond_synthesize", fond_body)
w_graph = words_for.("graph_validation", graph_body)

w_prim =
  words_for.("execute_primitive_step", fn ->
    PB2.with_run("wprim", fn -> PB2.record_only("wprim") end)
    :ok
  end)

w_seal =
  words_for.("receipt_seal", fn ->
    PB2.with_run("wseal", fn ->
      PB2.record_only("wseal")
      PB2.seal_only("wseal")
    end)
    :ok
  end)

w_runner =
  words_for.("fond_runner_total", fn ->
    {:ok, r} = run_one.()
    true = r.step_count == n_tasks
    :ok
  end)

words =
  Map.new([w_htn, w_fond, w_graph, w_prim, w_seal, w_runner])
  |> Map.put("receipt_seal_alone", elem(w_seal, 1) - elem(w_prim, 1))

rows =
  [
    {htn, "htn_decompose"},
    {fond, "fond_synthesize"},
    {graph, "graph_validation"},
    {prim, "execute_primitive_step"},
    {seal, "receipt_seal"},
    {seal_alone, "receipt_seal_alone"},
    {runner_total, "fond_runner_total"}
  ]
  |> Enum.map(fn {{name, reds, _ms}, _} ->
    %{
      stage: name,
      reductions: reds,
      words: Map.get(words, name),
      n_tasks: n_tasks,
      iters: iters,
      machine: machine
    }
  end)

File.write!(out, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
IO.puts("wrote #{out} (#{length(rows)} rows)")

# ---- pipeline sanity: stage reductions must compose to a sane order ----------

total_stage = elem(htn, 1) + elem(fond, 1) + elem(graph, 1) + elem(prim, 1) + elem(seal_alone, 1)
IO.puts("stage-composed total ≈ #{total_stage} reductions/orchestration (#{n_tasks} steps; per-step execute_primitive ≈ #{div(elem(prim, 1), n_tasks)})")
