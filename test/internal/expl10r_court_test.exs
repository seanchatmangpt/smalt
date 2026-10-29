defmodule Smalt.EXPL10R.HighRepairsCourtTest do
  @moduledoc """
  EXPL10-R court — flips for F1/F2/F3 from the EXPL-10 ERRC sweep
  (docs/jira/v26.10.22/receipts/expl10-pipeline-powl-errc.md, findings F1-F3,
  all witnessed). Each leg pins the post-repair verdict on the exact witness
  shape; non-vacuity: every leg failed pre-repair (probe transcripts embedded
  in the lane receipt).

  - F1: an unprovided need refuses the plan typed (unprovided_need) — never
    a sealed partial run.
  - F2: an unloadable reticle module refuses admission typed
    (admit_module_unloadable) — never a completed unadmitted run.
  - F3: 3-tuple errors and unknown op results refuse typed — never
    success-on-unknown; the documented {:ok_outcome, _} class still passes.
  """

  use ExUnit.Case, async: false

  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.Reticle.AST

  defp dets(name) do
    path = ~c"/tmp/expl10r_court_#{name}.dets"
    File.rm(path)
    {:ok, d} = :dets.open_file(name, file: path, repair: true)
    d
  end

  defp caller, do: self()

  defp drain do
    receive do
      m -> [m | drain()]
    after
      0 -> []
    end
  end

  defp po(children, order \\ []) do
    %AST.PartialOrder{children: Map.new(children, fn c -> {c.id, c} end), order: order}
  end

  defp trans(id, op, attrs \\ %{}) do
    struct(AST.Transition, Map.merge(%{id: id, label: Atom.to_string(id), op: op}, attrs))
  end

  # -- F1 ------------------------------------------------------------------

  describe "F1 unprovided need refuses the plan" do
    test "witness shape: step needing an unprovided term → {:crash, {unprovided_need, _}}" do
      plan = %{
        steps: [
          %{id: :a, needs: [], provides: [:a_out], action: :go},
          %{id: :b, needs: [:never_provided], provides: [:b_out], action: :go}
        ]
      }

      assert {:crash, {{:unprovided_need, [{:b, :never_provided}]}, _stk}} =
               :smalt_fond_powl_runner.run(%{plan: plan})
    end

    test "no seal ever lands for the refused plan" do
      plan = %{
        steps: [
          %{id: :a, needs: [], provides: [:a_out], action: :go},
          %{id: :b, needs: [:never_provided], provides: [:b_out], action: :go}
        ]
      }

      {:crash, _} = :smalt_fond_powl_runner.run(%{plan: plan})
      # The crash is the reply channel — a sealed receipt would arrive as
      # {:ok, _}. Nothing further to receive: run/1 is synchronous and the
      # crash reason already names the typed refusal, not a receipt.
      :ok
    end

    test "well-formed linear plan unchanged (happy path still seals)" do
      assert {:ok, r} = :smalt_fond_powl_runner.run(%{tasks: [:x, :y]})
      assert r.step_count == 2
      assert <<_::256>> = r.merkle
      assert r.plan == [:x, :y]
    end

    test "well-formed custom plan with real providers unchanged" do
      plan = %{
        steps: [
          %{id: :a, needs: [], provides: [:a_out], action: :go},
          %{id: :b, needs: [:a_out], provides: [:b_out], action: :go}
        ]
      }

      assert {:ok, r} = :smalt_fond_powl_runner.run(%{plan: plan})
      assert r.step_count == 2
    end
  end

  # -- F1-A (bkfondskep divergence flips) ----------------------------------

  describe "F1-A planner/executor satisfiability agreement" do
    @describetag :expl10r_f1a

    test "join shape (needs are bare step ids, no provides) now runs to completion" do
      plan = %{
        steps: [
          %{id: :j1, needs: [], provides: [], action: :go},
          %{id: :j2, needs: [], provides: [], action: :go},
          %{id: :j, needs: [:j1, :j2], provides: [], action: :go}
        ]
      }

      assert {:ok, r} = :smalt_fond_powl_runner.run(%{plan: plan})
      assert r.step_count == 3
    end

    test "done-id-only chain (need satisfied by a completed step id, no provides) runs" do
      plan = %{
        steps: [
          %{id: :a, needs: [], provides: [], action: :go},
          %{id: :b, needs: [:a], provides: [], action: :go}
        ]
      }

      assert {:ok, r} = :smalt_fond_powl_runner.run(%{plan: plan})
      assert r.step_count == 2
    end

    test "duplicate providers of one term no longer false-refuse as cyclic_plan" do
      plan = %{
        steps: [
          %{id: :a, needs: [], provides: [:x], action: :go},
          %{id: :b, needs: [], provides: [:x], action: :go},
          %{id: :c, needs: [:x], provides: [], action: :go}
        ]
      }

      assert {:ok, r} = :smalt_fond_powl_runner.run(%{plan: plan})
      assert r.step_count == 3
    end

    test "truly unprovided need still refuses typed (accept-direction stays closed)" do
      plan = %{
        steps: [
          %{id: :a, needs: [], provides: [], action: :go},
          %{id: :b, needs: [:never_provided], provides: [], action: :go}
        ]
      }

      assert {:crash, {{:unprovided_need, [{:b, :never_provided}]}, _stk}} =
               :smalt_fond_powl_runner.run(%{plan: plan})
    end

    test "real cycle still refuses as cyclic_plan" do
      plan = %{
        steps: [
          %{id: :a, needs: [:b], provides: [], action: :go},
          %{id: :b, needs: [:a], provides: [], action: :go}
        ]
      }

      assert {:crash, {{:cyclic_plan, remaining}, _stk}} = :smalt_fond_powl_runner.run(%{plan: plan})
      assert Enum.sort(remaining) == [:a, :b]
    end
  end

  # -- F2 ------------------------------------------------------------------

  describe "F2 unloadable reticle module refuses admission" do
    test "witness shape: nonexistent reticle mod → {:error, {:admit_module_unloadable, mod}}" do
      t = trans(:w2a, fn ctx -> {:ok, Map.put(ctx, :x, 1)} end)
      model = po([t])

      assert {:error, {:admit_module_unloadable, This.Reticle.Does.Not.Exist}} =
               Executor.execute_admitted(
                 :w2a,
                 {:ok, model},
                 %{},
                 dets(:f2),
                 caller(),
                 This.Reticle.Does.Not.Exist
               )

      assert Enum.any?(drain(), &match?({:orchestration_refused, :w2a, {:admit_module_unloadable, _}}, &1))
    end

    test "default reticle path unchanged (admitted model still completes)" do
      t = trans(:ok1, fn ctx -> {:ok, Map.put(ctx, :x, 1)} end)

      assert :ok = Executor.execute_admitted(:ok1, {:ok, po([t])}, %{}, dets(:f2b), caller())
      assert Enum.any?(drain(), &match?({:orchestration_completed, :ok1, _, _}, &1))
    end
  end

  # -- F3 ------------------------------------------------------------------

  describe "F3 op results are enumerated, never success-on-unknown" do
    test "witness shape: 3-tuple error → {:error, {:transition_failed, id, err3}}" do
      t = trans(:w2b, fn _ctx -> {:error, :throttled, :retry_after_5} end)

      assert {:error, {:transition_failed, :w2b, {:error, :throttled, :retry_after_5}}} =
               Executor.execute_admitted(:w2b, {:ok, po([t])}, %{}, dets(:f3a), caller())

      assert Enum.any?(drain(), &match?({:orchestration_failed, :w2b, {:transition_failed, :w2b, _}}, &1))
    end

    test "unknown op result shape refuses typed as bad_op_result" do
      t = trans(:weird, fn _ctx -> :bare_atom end)

      assert {:error, {:transition_failed, :weird, {:bad_op_result, :bare_atom}}} =
               Executor.execute_admitted(:weird, {:ok, po([t])}, %{}, dets(:f3b), caller())

      assert Enum.any?(drain(), &match?({:orchestration_failed, :weird, {:transition_failed, :weird, {:bad_op_result, :bare_atom}}}, &1))
    end

    test "documented {:ok_outcome, outcome} class still passes as an outcome" do
      t = trans(:okc, fn _ctx -> {:ok_outcome, :done_deal} end)

      assert :ok = Executor.execute_admitted(:okc, {:ok, po([t])}, %{}, dets(:f3c), caller())
      assert Enum.any?(drain(), &match?({:orchestration_completed, :okc, %{last_outcome: :done_deal}, _}, &1))
    end

    test "2-tuple {:error, reason} and {:ok, ctx} / {:ok, ctx, outcome} unchanged" do
      t1 = trans(:e2, fn _ctx -> {:error, :plain} end)
      assert {:error, {:transition_failed, :e2, :plain}} =
               Executor.execute_admitted(:e2, {:ok, po([t1])}, %{}, dets(:f3d), caller())

      t2 = trans(:ok2, fn ctx -> {:ok, Map.put(ctx, :a, 1)} end)
      assert :ok = Executor.execute_admitted(:ok2, {:ok, po([t2])}, %{}, dets(:f3d), caller())

      t3 = trans(:ok3, fn ctx -> {:ok, Map.put(ctx, :b, 2), :branched} end)
      assert :ok = Executor.execute_admitted(:ok3, {:ok, po([t3])}, %{}, dets(:f3d), caller())

      msgs = drain()

      assert Enum.any?(msgs, &match?({:orchestration_failed, :e2, _}, &1))
      assert Enum.any?(msgs, &match?({:orchestration_completed, :ok2, %{a: 1}, _}, &1))
      assert Enum.any?(msgs, &match?({:orchestration_completed, :ok3, %{b: 2, last_outcome: :branched}, _}, &1))
    end
  end
end
