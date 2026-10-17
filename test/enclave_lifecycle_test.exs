defmodule Smalt.Enclave.LifecycleTest do
  @moduledoc """
  The Go-free NFR-4 composite proof: the baseline terraform fixture
  lifecycle — parse -> in-process apply -> zero-drift plan -> tfstate
  synthesis -> destroy -> zero residue — runs green end to end in-process
  (no sockets, no ports, no terraform binary). Also extends the
  ets_baseline identity pattern: after destroy the Store ETS tables still
  EXIST (identity preserved) but are EMPTY (residue zero).
  """

  use ExUnit.Case, async: false

  alias Smalt.Enclave.Lifecycle
  alias Smalt.Store

  @fixture Path.expand("../test/terraform_fixture/main.tf", __DIR__)

  # The zero-residue assert reads EVERY resource-bearing Store table, so the
  # test must start from a clean store — ExUnit randomizes module order by
  # seed and other files' leftovers (vault kv-2 / secret s-2, "kv-shape")
  # would otherwise be reported as destroy residue (witnessed FR-6 T1/T2).
  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()

    # SHIM-COURT-pattern sink isolation: point the shared OCEL NDJSON sink
    # (`:smalt, :ocel_dir`, read at emit time by OcelNdjson.append/3) at a
    # per-suite scratch dir so concurrent-family suites' lifecycle events
    # never cross-pollute another suite's per-stage assertions. Restored in
    # on_exit (mirrors enclave_ocel/affidavit/court ocel suites).
    dir = Path.join("tmp", "ocel-lifecycle-test-#{System.system_time(:millisecond)}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:smalt, :ocel_dir)
    Application.put_env(:smalt, :ocel_dir, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:smalt, :ocel_dir, prev),
        else: Application.delete_env(:smalt, :ocel_dir)

      File.rm_rf!(dir)
    end)

    :ok
  end

  test "composite baseline fixture lifecycle: green end to end, in-process" do
    state_path =
      Path.join("tmp", "enclave-native-test-#{System.system_time(:millisecond)}.tfstate")

    assert {:ok, report} = Lifecycle.run(@fixture, state_path: state_path)

    # NFR-1: per-stage timings present, non-negative, at least one > 0.
    assert %{} = report.timings_ms

    assert MapSet.subset?(
             MapSet.new([:parse, :apply, :plan, :synthesize, :destroy, :residue]),
             MapSet.new(Map.keys(report.timings_ms))
           )

    assert Enum.all?(Map.values(report.timings_ms), &(is_integer(&1) and &1 >= 0))
    assert Enum.any?(Map.values(report.timings_ms), &(&1 > 0))

    # 3 resources provisioned through the real ARM router, ids on record.
    assert length(report.outcomes) == 3
    assert Enum.all?(report.outcomes, &is_binary(&1.id))
    rg = Enum.find(report.outcomes, &(&1.label == "azurerm_resource_group.smalt_fixture"))
    assert rg.id =~ "/resourceGroups/rg-smalt-fixture"

    # Zero-drift plan assert held (the lifecycle raised otherwise) and the
    # tfstate file exists with content.
    assert report.plan_diff == []
    assert File.exists?(report.state_path)
    assert {:ok, json} = Jason.decode(File.read!(report.state_path))
    assert map_size(json) == 3
    assert %{"id" => id, "attributes" => attrs} = json["azurerm_resource_group.smalt_fixture"]
    assert is_binary(id) and not is_nil(attrs)

    # Every id DELETEd and verified 404.
    assert length(report.deleted) == 3
    assert Enum.all?(report.deleted, & &1.verified)

    # NFR-4 residue: zero keys in every resource-bearing table.
    assert Enum.all?(report.residue, fn {_table, keys} -> keys == [] end)

    # ETS identity post-destroy: tables still alive (whereis not undefined)
    # but empty — identity preserved, state gone.
    refute :ets.whereis(:smalt_resources) == :undefined
    refute :ets.whereis(:smalt_resource_groups) == :undefined
    assert Store.keys(:smalt_resources) == []
    assert Store.keys(:smalt_resource_groups) == []
  end

  test "OCEL stage emission is fail-safe and registry-gated, never lifecycle-failing" do
    # Registry law (real collaborators, no stubs): emission flows through the
    # closed vocabulary gate — the typed outcome is DROP (type not yet
    # projected) or APPEND (regen landed), never a raise into the lifecycle.
    # Both branches leave a full lifecycle green with all six stages.
    registry_holds_type = Smalt.Ocel.EventRegistry.event_type?("enclave.lifecycle.stage")

    ctx = Smalt.Telemetry.EnclaveOcel.ctx(@fixture, [])
    emit_result = Smalt.Telemetry.EnclaveOcel.stage(:parse, 0, "ok", ctx)

    if registry_holds_type do
      assert {:ok, _path} = emit_result
    else
      assert {:ok, :dropped} = emit_result
    end

    state_path =
      Path.join("tmp", "enclave-native-test-#{System.system_time(:millisecond)}.tfstate")

    assert {:ok, report} = Lifecycle.run(@fixture, state_path: state_path)
    assert map_size(report.timings_ms) == 6
  end
end
