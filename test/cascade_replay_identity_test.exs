defmodule Smalt.CascadeReplayIdentityTest do
  @moduledoc """
  Replay-identity + non-vacuity + equivalence fence for the generated
  `lib/smalt/cascade_edges.ex` artifact (W2a).

  Three identities, one suite:

  1. **Artifact vs pack checkout** — re-rendering `cascade_edges.ex`
     from `../ggen-marketplace/packs/smalt-substrate-pack` (same pipeline
     as `mix smalt.gen`: Ontology.load! -> Engine.Graphlaw (fixed) ->
     build_bindings/1 -> Render.render/2, then `mix format`) must produce
     byte-identical output.

  2. **Coverage (the fence)** —
     `verify/cascade-coverage.unbound.rq` (two arms): (A) every
     smalt:CascadeEdge childTable resolves to a smalt:StoreTable
     individual (referential integrity), (B) every cascade-strategy
     StoreTable is referenced by >= 1 CascadeEdge. Zero rows live, and
     the gate must FIRE on a mutated ontology copy (drop the
     `ce-sa-blob-policy` edge -> arm B returns it) — a gate that cannot
     fire is the failure, not a pass.

  3. **Equivalence witness** — the generated dispatch table must cover
     every table the hand-written teardown paths sweep (the E2 census is
     the oracle): frozen per-parent witness below.

  `ggen_igniter` is a dev-only dep, so graphlaw runs go through a real
  `mix run --no-start` subprocess (MIX_ENV=dev) — the subprocess IS the
  replay being fenced.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @pack_dir "../ggen-marketplace/packs/smalt-substrate-pack"
  @artifact "lib/smalt/cascade_edges.ex"
  @verify_query @pack_dir <> "/verify/cascade-coverage.unbound.rq"

  # ---- equivalence witness (E2 census, frozen at the W2a swap) --------------
  # Oracle: the hand-written capture-then-sweep paths as of the swap
  # (arm_gateway/router.ex delete_rg / storageAccount DELETE / vault DELETE;
  # data_plane/blob_storage.ex drop_account_data; data_plane/cosmos.ex
  # drop_db/drop_container; enclave/state.ex destroy Metrics pass).
  @hand_written_sweep %{
    "Microsoft.Network/resourceGroups" => ~w(
      smalt_resources smalt_resource_groups smalt_blob_containers smalt_blobs
      smalt_blob_policy smalt_blob_blocks smalt_blob_snapshots
      smalt_vault_secrets smalt_cosmos_pk_meta
    )a,
    "Microsoft.Storage/storageAccounts" => ~w(
      smalt_resources smalt_blob_containers smalt_blobs smalt_blob_policy
      smalt_blob_blocks smalt_blob_snapshots smalt_metrics
    )a,
    "Microsoft.KeyVault/vaults" => ~w(
      smalt_resources smalt_vault_secrets smalt_metrics
    )a,
    "Microsoft.DocumentDb/sqlDatabases" => [:smalt_cosmos_pk_meta],
    "Microsoft.DocumentDb/sqlContainers" => [:smalt_cosmos_pk_meta],
    "smalt:enclave-destroy" => [:smalt_metrics]
  }

  @tag :replay_identity
  test "cascade_edges.ex replays byte-identical from the pack checkout" do
    %{out: out, path: out_path} = run_mix(replay_script())

    assert out =~ "RENDER_OK"

    {_out, 0} = System.cmd("mix", ["format", out_path], cd: root())

    generated = File.read!(out_path)
    on_disk = File.read!(Path.expand(@artifact, root()))

    assert generated == on_disk, """
    replay-identity FAILURE: a `mix smalt.gen`-equivalent render from the pack
    checkout is NOT byte-identical to #{@artifact}.

    If you hand-edited the artifact, restore it via `mix smalt.gen`.
    If you changed the pack (ontology/queries/template), re-baseline: run
    `mix smalt.gen` and land the regenerated artifact with the pack change.
    """
  end

  @tag :replay_identity
  test "verify gate is quiet on the live ontology and FIRES on a mutated copy" do
    # Mutated copy: drop EVERY CascadeEdge individual targeting
    # :smalt_blob_policy (ce-rg-blob-policy + ce-sa-blob-policy). Arm B is
    # per-TABLE, not per-edge: dropping one of two covering edges is not a
    # firing mutation. With both gone, :smalt_blob_policy (a
    # sweepStrategy="cascade" StoreTable) is uncovered and arm B returns it.
    ontology = File.read!(Path.expand(@pack_dir <> "/ontology.ttl", root()))

    mutated =
      ontology
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "-blob-policy a smalt:CascadeEdge"))
      |> Enum.join("\n")

    assert mutated != ontology, "mutation was vacuous: the blob-policy edges were not found"

    mutated_path = Path.expand("tmp/mutated-ontology-w2a.ttl", root())
    File.write!(mutated_path, mutated)
    on_exit(fn -> File.rm(mutated_path) end)

    %{out: out, path: out_path} =
      run_mix(verify_script(), %{"SMALT_MUTATED_ONTOLOGY" => mutated_path})

    assert out =~ "VERIFY_OK"

    # "0 N" — live ontology quiet, mutated copy fires (arm B: the dropped
    # edge leaves :smalt_blob_policy uncovered; N >= 1).
    assert ["0", fired] = out_path |> File.read!() |> String.trim() |> String.split(" ")

    assert String.to_integer(fired) >= 1, """
    non-vacuity FAILURE: expected verify/cascade-coverage.unbound.rq
    to return 0 rows on the live ontology and >= 1 row on a mutated copy
    (ce-sa-blob-policy CascadeEdge dropped). A coverage gate that cannot
    fire is the failure, not a pass.
    """
  end

  @tag :replay_identity
  test "every CascadeEdge childTable resolves to a StoreTable individual (referential integrity)" do
    store_tables = MapSet.new(Smalt.StoreTables.all_tables() |> Enum.map(&to_string/1))

    dangling =
      Smalt.CascadeEdges.edges()
      |> MapSet.new(&to_string(&1.table))
      |> MapSet.difference(store_tables)

    assert MapSet.size(dangling) == 0, """
    referential-integrity FAILURE: #{MapSet.size(dangling)} CascadeEdge
    childTable(s) have NO smalt:StoreTable row: #{dangling |> Enum.sort() |> Enum.join(", ")}
    """
  end

  @tag :replay_identity
  test "dispatch table covers every table the hand-written paths sweep (E2 oracle)" do
    for {parent, tables} <- @hand_written_sweep do
      covered =
        Smalt.CascadeEdges.edges()
        |> Enum.filter(&(&1.parent_resource == parent))
        |> MapSet.new(& &1.table)

      missing = MapSet.difference(MapSet.new(tables), covered)

      assert MapSet.size(missing) == 0, """
      equivalence FAILURE: parent #{parent} sweeps #{Enum.map_join(missing, ", ", & &1)}
      in the hand-written teardown paths but has NO CascadeEdge row.
      Add the edge to the pack ontology and regenerate `mix smalt.gen`.
      """

      # Anti-vacuity on the witness itself: every parent must actually
      # declare edges (an empty oracle map entry would pass vacuously).
      assert MapSet.size(covered) > 0
    end
  end

  test "the projected census matches the swap-time census (23 edges)" do
    # Anti-vacuity on the artifact itself: the ontology must actually
    # project the full E2 census, not an empty stub.
    assert length(Smalt.CascadeEdges.edges()) == 23
    assert length(Smalt.CascadeEdges.parent_resources()) == 6
    assert :smalt_blob_blocks in Smalt.CascadeEdges.tables()
  end

  # ---- subprocess plumbing (cloned from the store-tables replay fence) ------

  defp replay_script do
    """
    alias GgenIgniter.{Render, Engine.Graphlaw}
    pack = "#{@pack_dir}"
    tpl = File.read!(pack <> "/templates/cascade_edges.ex.eex")
    graph = GgenIgniter.Ontology.load!(pack <> "/ontology.ttl")
    ctx = Graphlaw.prepare!(graph, [])

    results =
      for {n, p} <- [
            {"cascade_edges", pack <> "/queries/cascade_edges.rq"}
          ] do
        {n, Graphlaw.run(ctx, File.read!(p))}
      end

    bindings = Mix.Tasks.GgenIgniter.Sync.build_bindings(results)
    out = Render.render(tpl, bindings)
    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, out)
    IO.puts("RENDER_OK " <> Integer.to_string(byte_size(out)))
    """
  end

  defp verify_script do
    """
    alias GgenIgniter.Engine.Graphlaw
    pack = "#{@pack_dir}"

    count_rows = fn ontology_path ->
      graph = GgenIgniter.Ontology.load!(ontology_path)
      ctx = Graphlaw.prepare!(graph, [])
      rows = Graphlaw.run(ctx, File.read!("#{@verify_query}"))
      length(rows)
    end

    live = count_rows.(pack <> "/ontology.ttl")

    mutated_path = System.get_env("SMALT_MUTATED_ONTOLOGY") || raise("SMALT_MUTATED_ONTOLOGY not set")
    mutated = count_rows.(mutated_path)

    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, "\#{live} \#{mutated}\\n")
    IO.puts("VERIFY_OK live=\#{live} mutated=\#{mutated}")
    """
  end

  defp run_mix(script, env \\ %{}) do
    out_path =
      Path.join(
        root(),
        "tmp/cascade-replay-" <> Integer.to_string(System.unique_integer([:positive])) <> ".ex"
      )

    File.mkdir_p!(Path.dirname(out_path))

    env = Map.merge(%{"SMALT_REPLAY_OUT" => out_path}, env)

    {out, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: root(),
        env: env,
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm(out_path) end)

    if status != 0 do
      flunk("replay subprocess failed (exit #{status}):\n" <> out)
    end

    %{out: out, path: out_path}
  end

  defp root, do: File.cwd!()
end
