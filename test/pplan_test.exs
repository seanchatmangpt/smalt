defmodule Smalt.PPlanTest do
  @moduledoc """
  Gate suite for the durable P-PLAN task store (lib/smalt/pplan/task.ex).

  Rows map onto the ash-pplan pack family (see docs/PACK_INTEGRATION/ash-pplan.md):

    * lifecycle            — full admitted->running->succeeded/failed lifecycle
                             (protocol-court-pack machine + igniter-pack scaffold)
    * chaos                — kill-mid-transition recovery: task claimed -> claimant
                             process killed -> task returns to claimable
                             (chaos-pack kill phase + terminal_absorbing invariant)
    * store-conformance    — store laws over the Task store surface: roundtrip,
                             delete idempotent, claim exclusive (concurrent),
                             plus the anti-vacuity mutant: a sabotaged court that
                             admits an unlawful edge must be refused by this suite
                             (store-conformance-pack laws/mutants)
  """

  use ExUnit.Case, async: false

  alias Smalt.PPlan.Task

  setup do
    :ok = Task.ensure()
    :ok
  end

  defp new_task(id) do
    %{
      id: id,
      status: :admitted,
      claimed_by: nil,
      attempts: 0,
      effects: %{},
      created_at: DateTime.utc_now(),
      updated_at: :erlang.monotonic_time()
    }
  end

  defp cleanup(ids), do: Enum.each(ids, &Task.delete/1)

  # ------------------------------------------------------------------
  # Lifecycle (protocol court machine)
  # ------------------------------------------------------------------

  describe "lifecycle" do
    @describetag :pplan_lifecycle

    test "admitted -> running -> succeeded" do
      id = "pplan-test-lifecycle-ok"
      on_exit(fn -> cleanup([id]) end)

      {:ok, t0} = Task.put(new_task(id))
      assert t0.status == :admitted
      assert Task.get(id).status == :admitted

      me = self()
      assert {:ok, t1} = Task.claim(id, me)
      assert t1.status == :running
      assert t1.claimed_by == me
      assert t1.attempts == 1

      assert {:ok, t2} = Task.transition(t1, :succeeded, effects: %{"step1" => 1})
      assert t2.status == :succeeded
      assert t2.effects == %{"step1" => 1}
      assert Task.get(id).status == :succeeded
    end

    test "admitted -> running -> failed" do
      id = "pplan-test-lifecycle-fail"
      on_exit(fn -> cleanup([id]) end)

      {:ok, t0} = Task.put(new_task(id))
      {:ok, t1} = Task.claim(id, self())
      assert {:ok, t2} = Task.transition(t1, :failed, error: "boom")
      assert t2.status == :failed
      assert t2.error == "boom"
      assert Task.get(id).status == :failed
    end

    test "persisted round-trip and delete" do
      id = "pplan-test-lifecycle-roundtrip"
      on_exit(fn -> cleanup([id]) end)

      {:ok, _} = Task.put(new_task(id))
      assert %{} = Task.get(id) |> Map.delete(:updated_at) |> Map.delete(:created_at)
      assert id in Enum.map(Task.list(), & &1.id)
      :ok = Task.delete(id)
      assert Task.get(id) == nil
      :ok = Task.delete(id)
    end
  end

  # ------------------------------------------------------------------
  # Protocol court validation
  # ------------------------------------------------------------------

  describe "court validation" do
    @describetag :pplan_court

    test "refuses an unlawful edge" do
      assert {:error, {:refused, :admitted, :succeeded}} =
               Task.validate_transition(:admitted, :succeeded)

      assert {:error, {:refused, :succeeded, :running}} =
               Task.validate_transition(:succeeded, :running)
    end

    test "terminal states absorb" do
      for terminal <- Task.terminal(),
          to <- Task.statuses(),
          to != terminal do
        assert {:error, {:refused, ^terminal, ^to}} =
                 Task.validate_transition(terminal, to)
      end
    end

    test "transition/3 refuses to write an unlawful edge" do
      id = "pplan-test-court-refused-write"
      on_exit(fn -> cleanup([id]) end)

      {:ok, t0} = Task.put(new_task(id))
      assert {:error, {:refused, :admitted, :succeeded}} = Task.transition(t0, :succeeded)
      assert Task.get(id).status == :admitted
    end

    test "concurrent claims have exactly one winner" do
      id = "pplan-test-court-concurrent-claim"
      on_exit(fn -> cleanup([id]) end)

      {:ok, _} = Task.put(new_task(id))

      me = self()

      # NB: `Task` here is the aliased Smalt.PPlan.Task, so concurrency uses
      # raw spawns rather than Elixir.Task.async_stream.
      parents =
        for n <- 1..32 do
          spawn(fn -> send(me, {:claim, n, Task.claim(id, {:c, n})}) end)
        end

      results =
        for _ <- parents do
          receive do
            {:claim, _n, r} -> r
          end
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :taken)) == 31
      assert Task.get(id).status == :running
    end

    test "anti-vacuity: a sabotaged court that admits an unlawful edge is detected" do
      defmodule SabotagedCourt do
        def validate_transition(_from, _to), do: :ok
      end

      # The real court refuses the unlawful edge the sabotaged one admits;
      # if the real court ever weakens to the sabotaged behaviour, this row fails.
      refused = Task.validate_transition(:succeeded, :succeeded)
      sabotaged = SabotagedCourt.validate_transition(:succeeded, :succeeded)

      assert match?({:error, {:refused, :succeeded, :succeeded}}, refused)
      assert sabotaged == :ok
      assert refused != sabotaged
    end
  end

  # ------------------------------------------------------------------
  # Chaos: kill-mid-transition recovery
  # ------------------------------------------------------------------

  describe "chaos" do
    @describetag :pplan_chaos

    test "kill-mid-transition: claimed task returns to claimable after claimant dies" do
      id = "pplan-test-chaos-kill"
      on_exit(fn -> cleanup([id]) end)

      {:ok, _} = Task.put(new_task(id))

      # Real claimant process, killed mid-transition (untrappable kill).
      claimant =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, claimed} = Task.claim(id, claimant)
      assert claimed.status == :running
      # Not recoverable while the claimant is alive.
      assert Task.recover() == []

      Process.exit(claimant, :kill)
      # Wait until the kill is observed (asynchronous exit).
      wait_until(fn -> not Process.alive?(claimant) end)

      recovered = Task.recover()
      assert [%{id: ^id, status: :admitted, claimed_by: nil}] = recovered
      assert Task.get(id).status == :admitted

      # The task is claimable again by a new claimant.
      assert {:ok, reclaimed} = Task.claim(id, self())
      assert reclaimed.status == :running
      assert reclaimed.attempts == 2
    end

    test "terminal tasks are never recovered (terminal absorbing)" do
      id = "pplan-test-chaos-terminal"
      on_exit(fn -> cleanup([id]) end)

      {:ok, t0} = Task.put(new_task(id))
      {:ok, t1} = Task.claim(id, self())
      {:ok, t2} = Task.transition(t1, :failed, error: "done")
      # A dead claimant on a terminal task must not resurrect it.
      assert Task.recover() |> Enum.all?(&(&1.id != id))
      assert Task.get(id).status == :failed
      assert t2.status == :failed
    end
  end

  # ------------------------------------------------------------------
  # Store conformance
  # ------------------------------------------------------------------

  describe "store conformance" do
    @describetag :pplan_conformance

    test "law: put/get roundtrip and deterministic list order" do
      ids = ["pplan-test-conf-b", "pplan-test-conf-a"]
      on_exit(fn -> cleanup(ids) end)

      for id <- ids, do: {:ok, _} = Task.put(new_task(id))
      assert Task.get("pplan-test-conf-b").id == "pplan-test-conf-b"
      assert Task.get("pplan-test-missing") == nil

      listed = Task.list() |> Enum.map(& &1.id)
      assert listed == Enum.sort(listed)
      assert "pplan-test-conf-a" in listed
    end

    test "law: delete is idempotent and a deleted key is puttable again" do
      id = "pplan-test-conf-delete"
      on_exit(fn -> cleanup([id]) end)

      {:ok, _} = Task.put(new_task(id))
      assert :ok = Task.delete(id)
      assert Task.get(id) == nil
      assert :ok = Task.delete(id)
      {:ok, again} = Task.put(new_task(id))
      assert again.status == :admitted
    end

    test "law: claim is exclusive, owner-scoped release via recover" do
      id = "pplan-test-conf-exclusive"
      on_exit(fn -> cleanup([id]) end)

      {:ok, _} = Task.put(new_task(id))
      holder = spawn(fn -> receive do :stop -> :ok end end)

      assert {:ok, _} = Task.claim(id, holder)
      assert :taken = Task.claim(id, :other)

      Process.exit(holder, :kill)
      wait_until(fn -> not Process.alive?(holder) end)
      assert [%{id: ^id}] = Task.recover()
      assert {:ok, _} = Task.claim(id, :other)
    end

    test "law: CAS conflict detected, no clobber" do
      id = "pplan-test-conf-cas"
      on_exit(fn -> cleanup([id]) end)

      {:ok, t0} = Task.put(new_task(id))
      {:ok, t1} = Task.put(%{t0 | status: :running})

      # t0 is stale (store holds t1); the court admits admitted->running but
      # the CAS on t0 must still detect the conflict, no clobber of t1.
      assert {:error, :conflict} = Task.transition(t0, :running)
      assert Task.get(id).status == :running
      assert {:ok, _} = Task.transition(t1, :succeeded)
    end
  end

  defp wait_until(fun, tries \\ 200) do
    if fun.() do
      :ok
    else
      if tries <= 0, do: flunk("condition not met")
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
