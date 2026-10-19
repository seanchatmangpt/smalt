defmodule Smalt.StoreTablesReplayIdentityTest do
  @moduledoc """
  Replay-identity + non-vacuity fence for the generated
  `lib/smalt/store_tables.ex` artifact (W1b, recipe steps 4/6/8).

  Three identities, one suite:

  1. **Artifact vs pack checkout** — re-rendering `store_tables.ex` from
     `../ggen-marketplace/packs/smalt-substrate-pack` (same pipeline as
     `mix smalt.gen`: Ontology.load! -> Engine.Graphlaw (fixed) ->
     build_bindings/1 -> Render.render/2, then `mix format`) must produce
     byte-identical output.

  2. **Coverage (the fence)** — every `:smalt_` atom referenced in `lib/`
     must be a row of the projected registry (owned or shadow). The
     ontology-side complement (every smalt:dataPlaneTable literal has a
     StoreTable row) is `verify/store-shadow-tables.unbound.rq`, run here
     through the same graphlaw engine: zero rows live, and the gate must
     FIRE on a mutated ontology copy (drop the `st-smalt_blob_policy`
     StoreTable individual -> exactly 1 row) — a gate that cannot fire is
     the failure, not a pass.

  3. **Equivalence witness** — the generated lists must equal the
     hand-written lists they replaced at the swap (33 owned / 11 metadata /
     6 persisted). Pinned as frozen snapshots below; if the ontology
     legitimately changes the surface, this test is the review point.

  `ggen_igniter` is a dev-only dep, so graphlaw runs go through a real
  `mix run --no-start` subprocess (MIX_ENV=dev) — the subprocess IS the
  replay being fenced.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 300_000
  @moduletag :stress

  @pack_dir "../ggen-marketplace/packs/smalt-substrate-pack"
  @artifact "lib/smalt/store_tables.ex"
  @verify_query @pack_dir <> "/verify/store-shadow-tables.unbound.rq"

  # ---- equivalence witness (step 7): frozen at the swap ---------------------
  @hand_written_tables ~w(
    smalt_subscriptions smalt_resource_groups smalt_resources smalt_operations
    smalt_cosmos_docs smalt_cosmos_lsn smalt_cosmos_pk_meta smalt_vault_keys
    smalt_vault_secrets smalt_appconfig smalt_blobs smalt_blob_containers
    smalt_blob_snapshots smalt_blob_policy smalt_ledger_transactions
    smalt_ledger_meta smalt_event_messages smalt_eg_topics smalt_sb_queues
    smalt_sb_messages smalt_sb_locks smalt_sb_sessions smalt_sb_tokens
    smalt_sb_rules smalt_eh_partitions smalt_eh_checkpoints
    smalt_sentinel_streams smalt_sentinel_rows smalt_purview_entities
    smalt_purview_edges smalt_resource_graph_tokens smalt_attestation_baseline
    smalt_metrics smalt_q_queues smalt_q_messages
  )a
  @hand_written_metadata ~w(
    smalt_operations smalt_subscriptions smalt_cosmos_lsn smalt_ledger_meta
    smalt_sb_tokens smalt_sb_locks smalt_sb_sessions smalt_eh_checkpoints
    smalt_resource_graph_tokens smalt_attestation_baseline smalt_sentinel_streams
  )a
  @hand_written_persisted ~w(
    smalt_resources smalt_cosmos_docs smalt_blobs smalt_ledger_transactions
    smalt_ledger_meta smalt_event_messages
  )a

  @tag :replay_identity
  test "store_tables.ex replays byte-identical from the pack checkout" do
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
    # Mutated copy: drop the st-smalt_blob_policy StoreTable individual.
    # blob_policy IS a smalt:dataPlaneTable literal, so its removal must make
    # the gate return exactly 1 row (the :smalt_blob_blocks bug class,
    # reproduced synthetically).
    ontology = File.read!(Path.expand(@pack_dir <> "/ontology.ttl", root()))

    mutated =
      ontology
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "smalt:tableName \"smalt_blob_policy\""))
      |> Enum.join("\n")

    assert mutated != ontology, "mutation was vacuous: the blob_policy row was not found"

    mutated_path = Path.expand("tmp/mutated-ontology-w1b.ttl", root())
    File.write!(mutated_path, mutated)
    on_exit(fn -> File.rm(mutated_path) end)

    %{out: out, path: out_path} =
      run_mix(verify_script(), %{"SMALT_MUTATED_ONTOLOGY" => mutated_path})

    assert out =~ "VERIFY_OK"

    # "0 N" — live ontology quiet, mutated copy fires (N = the sweep-group
    # rows referencing the dropped table, N >= 1).
    assert ["0", fired] = out_path |> File.read!() |> String.trim() |> String.split(" ")

    assert String.to_integer(fired) >= 1, """
    non-vacuity FAILURE: expected verify/store-shadow-tables.unbound.rq
    to return 0 rows on the live ontology and >= 1 row on a mutated copy
    (st-smalt_blob_policy StoreTable individual dropped). A coverage gate
    that cannot fire is the failure, not a pass.
    """
  end

  @tag :replay_identity
  test "every :smalt_ atom referenced in lib/ is a registry row (coverage)" do
    referenced =
      Path.wildcard("lib/**/*.ex")
      |> Map.new(fn path ->
        {path, path |> File.read!() |> then(&Regex.scan(~r/:smalt_[a-z_0-9]+/, &1))}
      end)
      |> Enum.flat_map(fn {path, atoms} -> Enum.map(atoms, fn [a] -> {a, path} end) end)

    registry = MapSet.new(Smalt.StoreTables.all_tables() |> Enum.map(&to_string/1))

    uncovered =
      referenced
      |> MapSet.new(fn {a, _path} -> String.trim_leading(a, ":") end)
      |> MapSet.difference(registry)

    assert MapSet.size(uncovered) == 0, """
    coverage FAILURE: #{MapSet.size(uncovered)} :smalt_ atom(s) referenced in lib/ \
    have NO smalt:StoreTable row in the ontology (swept-but-unowned bug class):

    #{uncovered |> Enum.sort() |> Enum.join("\n")}

    Fix: add the individual to the pack ontology, regenerate `mix smalt.gen`.
    """

    # The registry must not be trivially empty either (anti-vacuity on this
    # test itself): the census is 55 atoms (35 owned + 20 shadow).
    assert length(Smalt.StoreTables.table_names()) == 35
    assert length(Smalt.StoreTables.shadow_tables()) == 20
  end

  test "generated lists equal the hand-written lists they replaced (step 7 witness)" do
    assert Smalt.StoreTables.table_names() |> Enum.sort() == Enum.sort(@hand_written_tables)
    assert Smalt.StoreTables.metadata_tables() |> Enum.sort() == Enum.sort(@hand_written_metadata)

    assert Smalt.StoreTables.persisted_tables() |> Enum.sort() ==
             Enum.sort(@hand_written_persisted)
  end

  # ---- subprocess plumbing (cloned from the registry replay fence) ----------

  defp replay_script do
    """
    alias GgenIgniter.{Render, Engine.Graphlaw}
    pack = "#{@pack_dir}"
    tpl = File.read!(pack <> "/templates/store_tables.ex.eex")
    graph = GgenIgniter.Ontology.load!(pack <> "/ontology.ttl")
    ctx = Graphlaw.prepare!(graph, [])

    results =
      for {n, p} <- [
            {"store_tables", pack <> "/queries/store_tables.rq"}
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
        "tmp/store-tables-replay-" <>
          Integer.to_string(System.unique_integer([:positive])) <> ".ex"
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
