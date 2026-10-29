defmodule Smalt.SpofbEhAtomCourtTest do
  @moduledoc """
  SPOF-B falsification court (A-2 / A-4 / A-5 / A-6) — real collaborators,
  Chicago-style: real process exits, real DETS files, real atom-count deltas.
  No mocks, no sleeps (bounded polls + monitor-based exit waits).
  """

  use ExUnit.Case, async: false

  alias Smalt.Messaging.EventHubs
  alias Smalt.Messaging.EventHubs.Server, as: EHServer
  alias Smalt.Messaging.EhGeoDr
  alias Smalt.Powl2.ServiceBusRuleManager

  @partitions :smalt_eh_partitions
  @checkpoints :smalt_eh_checkpoints

  defp atom_count, do: :erlang.system_info(:atom_count)

  defp ms_now, do: System.system_time(:millisecond)

  # Bounded poll on a real observable (no-sleep law): convergence within budget.
  defp eventually(fun, deadline \\ ms_now() + 5_000)

  defp eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if ms_now() > deadline do
        flunk("observable did not converge within 5s")
      end

      eventually(fun, deadline)
    end
  end

  defp wait_pid_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    :ok
  end

  # ---------------------------------------------------------------- A-2 -----
  test "A-2: EHServer is a supervised child (not a lazy first-caller singleton)" do
    # Bounded poll: under a random ExUnit order a sibling kill-test may be
    # mid-restart-window; the claim is convergence, not a snapshot.
    eventually(fn -> w = Process.whereis(EHServer); w != nil and Process.alive?(w) end)
    pid = Process.whereis(EHServer)

    {:links, links} = Process.info(pid, :links)
    sup = Process.whereis(Smalt.Plane.IntegrationSupervisor)
    assert sup != nil
    assert Enum.any?(links, &(&1 == sup)), "EHServer must be linked to IntegrationSupervisor"
  end

  test "A-2: kill the EHServer owner mid-flight — tables survive via heir, client state intact" do
    partition = "test-hub/spofb-court/partitions/0"
    cg_key = {"spofb-cg", partition}

    # Boot-readiness gate (bounded): under concurrent-lane port contention the
    # app boot can wobble (witnessed EXIT :shutdown on a first call); the
    # claim under test is post-convergence behavior, never boot timing.
    eventually(
      fn ->
        w = Process.whereis(EHServer)

        try do
          w != nil and Process.alive?(w) and EventHubs.ensure_tables() == :ok
        rescue
          _ -> false
        catch
          :exit, _ -> false
        end
      end,
      ms_now() + 15_000
    )

    {:ok, seq1, _} = EventHubs.send_event(partition, "spofb-e1")
    {:ok, seq2, _} = EventHubs.send_event(partition, "spofb-e2")
    assert seq2 == seq1 + 1

    :ok =
      EventHubs.compare_and_swap(
        "spofb-cg",
        partition,
        %{"seq" => 0, "offset" => 0, "etag" => 0},
        %{"seq" => seq2, "offset" => Integer.to_string(seq2), "etag" => seq2}
      )

    {:ok, pre} = EventHubs.reconcile("spofb-cg", partition)

    # REAL exit: hard kill of the table owner.
    owner = Process.whereis(EHServer)
    Process.exit(owner, :kill)
    wait_pid_exit(owner)

    # Supervision restarts the owner; the heir'd tables never dropped.
    eventually(
      fn ->
        w = Process.whereis(EHServer)
        w != nil and w != owner
      end,
      ms_now() + 15_000
    )

    assert :ets.info(@partitions) != :undefined
    assert :ets.info(@checkpoints) != :undefined

    # Structural non-vacuity face: every EH table carries a live heir. On a
    # full-plane boot Smalt.Store (TTV-5) may have created the partitions/
    # checkpoints tables first with its own Heir — either way the table must
    # be heir'd (the pre-patch tables carried NO heir at all), and the
    # EHServer-owned `:smalt_eh_cgs` table must be :init-heir'd.
    for t <- [@partitions, @checkpoints, :smalt_eh_cgs] do
      heir = :ets.info(t, :heir)
      assert is_pid(heir) and (heir == Process.whereis(:init) or Process.alive?(heir)),
             "table #{inspect(t)} must carry a live heir, got: #{inspect(heir)}"
    end

    assert :ets.info(:smalt_eh_cgs, :heir) == Process.whereis(:init)

    # Re-connected client: seq monotonicity and the checkpoint survived.
    {:ok, seq3, _} = EventHubs.send_event(partition, "spofb-e3")
    assert seq3 == seq2 + 1

    {:ok, rec} = EventHubs.reconcile("spofb-cg", partition)
    assert rec["checkpoint"]["seq"] == pre["checkpoint"]["seq"]

    :ets.delete(@partitions, partition)
    :ets.delete(@checkpoints, cg_key)
  end

  # ---------------------------------------------------------------- A-4 -----
  test "A-4: ServiceBusRuleManager kill — rule survives via heir" do
    if is_nil(Process.whereis(ServiceBusRuleManager)) do
      {:ok, _} = GenServer.start(ServiceBusRuleManager, :ok, name: ServiceBusRuleManager)
    end

    test_pid = self()
    :ok = ServiceBusRuleManager.put_rule("spofb-t", "spofb-s", "$Default", :true_filter, test_pid)

    owner = Process.whereis(ServiceBusRuleManager)
    Process.exit(owner, :kill)
    wait_pid_exit(owner)

    assert :ets.info(ServiceBusRuleManager.table()) != :undefined
    assert :ets.info(ServiceBusRuleManager.dlq()) != :undefined
    assert [{_, {true, nil}, ^test_pid}] = ServiceBusRuleManager.get_rules("spofb-t", "spofb-s")

    ServiceBusRuleManager.delete_rule("spofb-t", "spofb-s", "$Default")
  end

  test "A-4: EhGeoDr kill — alias metadata survives via heir" do
    alias_name = "spofb-alias-#{System.unique_integer([:positive])}"
    {:ok, rec} = EhGeoDr.create_or_update_alias(alias_name, "ns-primary", "ns-partner")
    assert rec["provisioning_state"] == "Succeeded"

    owner = Process.whereis(EhGeoDr)
    Process.exit(owner, :kill)
    wait_pid_exit(owner)

    # A re-connected caller re-adopts (lazy fallback) and reads surviving data.
    assert {:ok, rec2} = EhGeoDr.get_alias(alias_name)
    assert rec2["primary_namespace_id"] == "ns-primary"
    assert rec2["provisioning_state"] == "Succeeded"

    EhGeoDr.delete_alias(alias_name)
  end

  test "A-4/A-6: change_feed table-name atoms stable across restarts (ratio fence)" do
    # Caller face: `base` names the statem and is the CALLER's atom (minted
    # here once, reused for the second wave). The module's own minting is the
    # claim under test: table names must mint ZERO atoms.
    bases =
      for i <- 1..40, do: String.to_atom("spofb_cf_base_#{i}")

    init_pid = Process.whereis(:init)

    unnamed_heir_set_count = fn ->
      Enum.count(:ets.all(), fn t ->
        :ets.info(t, :named_table) == false and :ets.info(t, :heir) == init_pid and
          :ets.info(t, :type) == :set
      end)
    end

    # Warm wave: byte-identical ops to the measured wave (start + put) so
    # all one-time code-loading atoms land OUTSIDE the measured window.
    pids =
      Enum.map(bases, fn base ->
        {:ok, pid} = Smalt.POWL2.ChangeFeed.start_link(base: base)
        {:ok, 201, _} = Smalt.POWL2.ChangeFeed.put_item(pid, "pk", "id1", "body")
        pid
      end)

    Enum.each(pids, &GenServer.stop/1)

    before = unnamed_heir_set_count.()
    a0 = atom_count()

    # Steady wave: 40 fresh starts on EXISTING atoms — zero module-side mints.
    pids2 =
      Enum.map(bases, fn base ->
        {:ok, pid} = Smalt.POWL2.ChangeFeed.start_link(base: base)
        {:ok, 201, _} = Smalt.POWL2.ChangeFeed.put_item(pid, "pk", "id1", "body")
        pid
      end)

    delta = atom_count() - a0

    # Ratio fence (absolute zero is flaky under ambient VM atom noise —
    # witnessed Store.Heir restart churn): the reverted `:"#\{base}_docs"`
    # shape mints >= 2N per wave (>= 80 for N=40: _docs AND _cdc names);
    # the fixed shape is ~0. Ambient noise witnessed at 9 mints in one
    # window (BK-104 run 6); the fence allows <= 9 ambient mints and the
    # mutation cannot pass it.
    assert delta * 4 < length(bases),
           "change_feed minted #{delta} atoms for #{length(bases)} table pairs (ratio fence)"

    assert unnamed_heir_set_count.() - before == 40, "40 unnamed heir'd doc tables"

    Enum.each(pids2, &GenServer.stop/1)
  end

  # ---------------------------------------------------------------- A-5 -----
  test "A-5: distinct run_ids are atom-neutral (charlist dets names, ratio fence); re-open replays" do
    dir = Path.join([File.cwd!(), "tmp/spofb_receipts_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Warm the DETS subsystem (same opts shape as ReceiptEngine.open/2) so
    # module-load atoms land outside the measured window.
    {:ok, w} =
      :dets.open_file(~c"warm",
        file: String.to_charlist(Path.join(dir, "warm.dets")),
        type: :duplicate_bag,
        repair: true,
        auto_save: 5_000
      )

    :dets.close(w)

    # Warm wave (one-time atoms: code paths, Logger faces).
    warm_id = "spofb-warm-#{System.unique_integer([:positive])}"
    {:ok, _} = Smalt.PPlan.ReceiptEngine.open(warm_id, Path.join(dir, "warm2.dets"))
    Smalt.PPlan.ReceiptEngine.record_step(warm_id, %{epoch: 1, act: "a", delta: :d})
    :ok = Smalt.PPlan.ReceiptEngine.close(warm_id)

    n = 500
    a0 = atom_count()

    for i <- 1..n do
      run_id = "spofb-run-#{i}-#{System.unique_integer([:positive])}"
      {:ok, ^run_id} = Smalt.PPlan.ReceiptEngine.open(run_id, Path.join(dir, "r#{i}.dets"))
      Smalt.PPlan.ReceiptEngine.record_step(run_id, %{epoch: 1, act: "a", delta: :d})
      :ok = Smalt.PPlan.ReceiptEngine.close(run_id)
    end

    delta = atom_count() - a0

    # Ratio fence (absolute zero is flaky under ambient VM atom noise):
    # the reverted String-to-atom-per-run shape mints >= n; the charlist
    # shape is ~0. Fence: delta * 20 < n (<= 24 ambient mints tolerated,
    # mutation cannot pass).
    assert delta * 20 < n,
           "pplan receipts minted #{delta} atoms over #{n} runs (ratio fence)"

    # Re-open replays the file — behavior identical to the atom-name era.
    {:ok, _} = Smalt.PPlan.ReceiptEngine.open(warm_id, Path.join(dir, "warm2.dets"))
    steps = Smalt.PPlan.ReceiptEngine.steps(warm_id)
    assert length(steps) == 1
    assert hd(steps).act_iri =~ warm_id
    :ok = Smalt.PPlan.ReceiptEngine.close(warm_id)
  end

  # ---------------------------------------------------------------- A-6 -----
  test "A-6: powl_bridge + change_feed carry no unguarded atom-minting sites" do
    refute File.read!("lib/smalt/ocel/revops/powl_bridge.ex") =~ "String.to_atom"
    src_cf = File.read!("lib/smalt/powl2/change_feed.ex")
    refute src_cf =~ "to_atom"
    refute src_cf =~ ~S|:"#{base}|
  end
end
