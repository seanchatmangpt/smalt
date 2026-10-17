defmodule Smalt.SemconvReplayIdentityTest do
  @moduledoc """
  Replay-identity + non-vacuity fence for the generated
  `lib/smalt/telemetry/semconv/registry.ex` artifact (W2b: the hand-sync of
  smalt.yaml → registry.ex becomes a true projection from the
  smalt-semconv-pack ontology).

  Three identities, one suite:

  1. **Artifact vs pack checkout** — re-rendering `registry.ex` from
     `../ggen-marketplace/packs/smalt-semconv-pack` (same pipeline as
     `mix smalt.gen`: Ontology.load! -> Engine.Graphlaw (fixed) ->
     build_bindings/1 -> Render.render/2, then `mix format`) must produce
     byte-identical output.

  2. **YAML↔graph census** — every span/event name in the mirrored model
     `lib/smalt/telemetry/semconv/model/smalt.yaml` must have a
     smaltv:SemConvEvent row in the ontology (7 names / 14 attribute rows /
     10 OTEL→OCEL rules), so the YAML fence (test/semconv_test.exs) and the
     graph projection cannot silently diverge.

  3. **Verify-gate non-vacuity** — `verify/semconv-coverage.unbound.rq`
     must return 0 rows on the live ontology and FIRES on a mutated pack
     copy (drop the `smalt.blob.custody` name triple -> 1 row). A gate
     that cannot fire is the failure, not a pass.

  `ggen_igniter` is a dev-only dep, so graphlaw runs go through a real
  `mix run --no-start` subprocess (MIX_ENV=dev) — the subprocess IS the
  replay being fenced.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @pack_dir "../ggen-marketplace/packs/smalt-semconv-pack"
  @artifact "lib/smalt/telemetry/semconv/registry.ex"
  @model "lib/smalt/telemetry/semconv/model/smalt.yaml"
  @verify_query @pack_dir <> "/verify/semconv-coverage.unbound.rq"

  @census_attr_rows 14
  @census_rule_rows 10

  @tag :replay_identity
  test "registry.ex replays byte-identical from the pack checkout" do
    %{out: out, path: out_path} = run_mix(replay_script())

    assert out =~ "RENDER_OK"

    {_out, 0} = System.cmd("mix", ["format", out_path], cd: root())

    generated = File.read!(out_path)

    on_disk = File.read!(Path.expand(@artifact, root()))

    assert generated == on_disk, """
    replay-identity FAILURE: a `mix smalt.gen`-equivalent render from the
    smalt-semconv-pack checkout is NOT byte-identical to #{@artifact}.

    If you hand-edited the artifact, restore it via `mix smalt.gen`.
    If you changed the pack (ontology/queries/template), re-baseline: run
    `mix smalt.gen` and land the regenerated artifact + pack change together.
    """
  end

  @tag :replay_identity
  test "verify gate is quiet on the live ontology and FIRES on a mutated copy" do
    # Mutated copy: drop the smaltv:name triple from the smalt.blob.custody
    # individual — the verify gate must return >= 1 row (the nameless
    # SemConvEvent).
    ontology = File.read!(Path.expand(@pack_dir <> "/ontology.ttl", root()))

    mutated =
      ontology
      |> String.split("\n")
      |> Enum.reject(&String.contains?(&1, "smaltv:name \"smalt.blob.custody\""))
      |> Enum.join("\n")

    assert mutated != ontology, "mutation was vacuous: the blob.custody row was not found"

    mutated_path = Path.expand("tmp/mutated-ontology-w2b.ttl", root())
    File.write!(mutated_path, mutated)
    on_exit(fn -> File.rm(mutated_path) end)

    %{out: out, path: out_path} =
      run_mix(verify_script(), %{"SMALT_MUTATED_ONTOLOGY" => mutated_path})

    assert out =~ "VERIFY_OK"

    # "<live> <mutated>" — live quiet, mutated copy fires.
    assert [live, fired] = out_path |> File.read!() |> String.trim() |> String.split(" ")

    assert live == "0", "verify gate is not quiet on the live ontology: #{live} rows"

    assert String.to_integer(fired) >= 1, """
    non-vacuity FAILURE: expected verify/semconv-coverage.unbound.rq to
    return 0 rows on the live ontology and >= 1 row on a mutated copy
    (smalt.blob.custody smaltv:name triple dropped). A coverage gate that
    cannot fire is the failure, not a pass.
    """
  end

  @tag :replay_identity
  test "every span/event name in the model YAML has an ontology row (census)" do
    yaml = File.read!(Path.expand(@model, root()))

    yaml_names =
      Regex.scan(~r/^\s+- (?:name|type): (smalt\.[a-z_.]+)$/m, yaml)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    ontology = File.read!(Path.expand(@pack_dir <> "/ontology.ttl", root()))

    ontology_names =
      Regex.scan(~r/smaltv:name "([^"]+)"/, ontology)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()

    missing = MapSet.difference(MapSet.new(yaml_names), MapSet.new(ontology_names))

    assert MapSet.size(missing) == 0, """
    census FAILURE: #{MapSet.size(missing)} model YAML name(s) have NO
    smaltv:SemConvEvent row in the pack ontology:

    #{missing |> Enum.sort() |> Enum.join("\n")}

    Fix: add the individual to smalt-semconv-pack ontology.ttl, regenerate
    `mix smalt.gen`, and keep test/semconv_test.exs green.
    """

    # Both censuses are non-trivial: 7 names on each side.
    assert length(yaml_names) == 7
    assert length(ontology_names) == 7
  end

  test "graph census pins the pack surface (anti-vacuity on this suite)" do
    %{out: out, path: out_path} = run_mix(census_script())

    assert out =~ "CENSUS_OK"

    # "7 14 10" — names / attribute rows / OTEL→OCEL rules.
    assert ["7", "14", "10"] =
             out_path |> File.read!() |> String.trim() |> String.split(" ")

    assert @census_attr_rows == 14 and @census_rule_rows == 10
  end

  # ---- subprocess plumbing (cloned from the store-tables replay fence) ------

  defp replay_script do
    """
    alias GgenIgniter.{Render, Engine.Graphlaw}
    pack = "#{@pack_dir}"
    tpl = File.read!(pack <> "/templates/registry.ex.eex")
    graph = GgenIgniter.Ontology.load!(pack <> "/ontology.ttl")
    ctx = Graphlaw.prepare!(graph, [])

    results =
      for {n, p} <- [
            {"semconv_events", pack <> "/queries/semconv_events.rq"},
            {"semconv_bindings", pack <> "/queries/semconv_bindings.rq"},
            {"semconv_attributes", pack <> "/queries/semconv_attributes.rq"},
            {"semconv_mapping_rules", pack <> "/queries/semconv_mapping_rules.rq"}
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

    mutated_path =
      System.get_env("SMALT_MUTATED_ONTOLOGY") || raise("SMALT_MUTATED_ONTOLOGY not set")

    mutated = count_rows.(mutated_path)

    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, "\#{live} \#{mutated}\\n")
    IO.puts("VERIFY_OK live=\#{live} mutated=\#{mutated}")
    """
  end

  defp census_script do
    """
    alias GgenIgniter.Engine.Graphlaw
    pack = "#{@pack_dir}"
    graph = GgenIgniter.Ontology.load!(pack <> "/ontology.ttl")
    ctx = Graphlaw.prepare!(graph, [])

    count = fn q ->
      Graphlaw.run(ctx, File.read!(pack <> "/queries/" <> q)) |> length()
    end

    names = count.("semconv_events.rq")
    attrs = count.("semconv_attributes.rq")
    rules = count.("semconv_mapping_rules.rq")
    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, "\#{names} \#{attrs} \#{rules}\\n")
    IO.puts("CENSUS_OK names=\#{names} attrs=\#{attrs} rules=\#{rules}")
    """
  end

  defp run_mix(script, env \\ %{}) do
    out_path =
      Path.join(
        root(),
        "tmp/semconv-replay-" <>
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
