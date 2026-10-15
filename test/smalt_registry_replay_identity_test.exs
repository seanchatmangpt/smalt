defmodule Smalt.RegistryReplayIdentityTest do
  @moduledoc """
  Replay-identity fence for the generated `lib/smalt/registry.ex` artifact.

  Two identities, one test suite (lens-3 lead item, root-caused 2026-10-15):

  1. **Artifact vs pack checkout** — re-rendering `registry.ex` from
     `../ggen-marketplace/packs/smalt-substrate-pack` (same pipeline as
     `mix smalt.gen`: Ontology.load! -> Query.run/2 sparql -> build_bindings/1
     -> Render.render/2, then `mix format`) must produce byte-identical
     output. Found live: the on-disk artifact could NOT be replayed —
     section-2/3 row order was a generation-time accident of the `sparql`
     engine's missing ORDER BY support (membership was identical, so no
     hand-edit). Fixed by canonical (resourceType) sorting in the pack
     template + re-baseline; this test pins it.

  2. **Lock vs live pack** — `ggen_igniter.pack.lock`'s pinned sha256 for
     `smalt-substrate-pack` must equal `GgenIgniter.PackLock.digest/1` of the
     live pack checkout (`:lock_drift` class, routed from the semantic-
     projection lens-2 lane). Found live: lock pinned `70a135be…`, live pack
     computes `4fe9d26c…`.

  `ggen_igniter` is a dev-only dep, so both checks run through a real
  `mix run --no-start` subprocess (MIX_ENV=dev) rather than an in-process
  call — the subprocess IS the replay being fenced.
  """

  use ExUnit.Case, async: false

  @pack_dir "../ggen-marketplace/packs/smalt-substrate-pack"
  @artifact "lib/smalt/registry.ex"
  @lock_file "ggen_igniter.pack.lock"

  @tag :replay_identity
  test "registry.ex replays byte-identical from the pack checkout" do
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
  test "pack lock digest matches the live pack checkout" do
    %{out: out, path: out_path} = run_mix(lock_script())

    assert out =~ "DIGEST_OK"

    [live, locked] = out_path |> File.read!() |> String.trim() |> String.split(" ")

    assert live == locked, """
    :lock_drift — ggen_igniter.pack.lock pins #{locked} but the live pack at
    #{@pack_dir} computes #{live} (GgenIgniter.PackLock.digest/1). The
    artifact-vs-lock drift fence cannot see this class (it never compares the
    lock to the live pack). Re-pin with:
    mix ggen_igniter.pack.lock --path #{@pack_dir} --pack smalt-substrate-pack
    """
  end

  defp replay_script do
    """
    alias GgenIgniter.{Ontology, Query, Render}
    pack = "#{@pack_dir}"
    tpl = File.read!(pack <> "/templates/registry.ex.eex")
    graph = Ontology.load!(pack <> "/ontology.ttl")

    results =
      for {n, p} <- [
            {"control_plane", pack <> "/queries/control_plane.rq"},
            {"payload_rules", pack <> "/queries/payload_rules.rq"}
          ] do
        {n, Query.run(graph, File.read!(p))}
      end

    bindings = Mix.Tasks.GgenIgniter.Sync.build_bindings(results)
    out = Render.render(tpl, bindings)
    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, out)
    IO.puts("RENDER_OK " <> Integer.to_string(byte_size(out)))
    """
  end

  defp lock_script do
    """
    live = GgenIgniter.PackLock.digest("#{@pack_dir}")
    {:ok, body} = File.read("#{@lock_file}")
    %{"packs" => %{"smalt-substrate-pack" => %{"sha256" => locked}}} = Jason.decode!(body)
    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, live <> " " <> locked <> "\\n")
    IO.puts("DIGEST_OK")
    """
  end

  defp run_mix(script) do
    out_path =
      Path.join(
        root(),
        "tmp/replay-identity-" <> Integer.to_string(System.unique_integer([:positive])) <> ".ex"
      )

    File.mkdir_p!(Path.dirname(out_path))

    {out, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        cd: root(),
        env: %{"SMALT_REPLAY_OUT" => out_path},
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
