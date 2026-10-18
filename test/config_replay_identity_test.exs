defmodule Smalt.ConfigReplayIdentityTest do
  @moduledoc """
  Replay-identity fence for the generated `lib/smalt/config.ex` (W1a).

  Clones the registry replay pattern (test/smalt_registry_replay_identity_test.exs):
  a real `mix run --no-start` subprocess re-renders config.ex from the pack
  checkout (same pipeline as `mix smalt.gen`: Ontology.load! -> Engine.Graphlaw
  -> build_bindings -> Render.render, then `mix format`), byte-compares
  against the on-disk artifact, and checks the pack lock digest. The same
  subprocess runs the pack gates: coverage >= 1 row, bijection zero rows,
  census == 47.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 240_000
  @moduletag :stress

  @pack_dir "../ggen-marketplace/packs/smalt-substrate-pack"
  @artifact "lib/smalt/config.ex"
  @lock_file "ggen_igniter.pack.lock"

  @tag :replay_identity
  test "config.ex replays byte-identical from the pack checkout" do
    %{out: out, path: out_path} = run_mix(replay_script())

    assert out =~ "RENDER_OK"

    {_out, 0} = System.cmd("mix", ["format", out_path], cd: root())

    generated = File.read!(out_path)
    on_disk = File.read!(Path.expand(@artifact, root()))

    assert generated == on_disk, """
    replay-identity FAILURE: a `mix smalt.gen`-equivalent render of config.ex
    is NOT byte-identical to lib/smalt/config.ex. Re-baseline: `mix smalt.gen`.
    """
  end

  @tag :replay_identity
  test "override semantics are mirrored on the projected accessors" do
    on_disk = File.read!(Path.expand(@artifact, root()))

    # env-first class (bind_ip)
    assert on_disk =~
             "def bind_ip, do: System.get_env(\"SMALT_BIND_IP\") || Application.get_env(:smalt, :bind_ip)"

    # app-env-first class (blob_account_key)
    assert on_disk =~
             "Application.get_env(:smalt, :blob_account_key) || System.get_env(\"SMALT_BLOB_ACCOUNT_KEY\")"

    # plain default class (arm_port)
    assert on_disk =~ "def arm_port, do: Application.get_env(:smalt, :arm_port, 9443)"
    # nilable (sts_signing_secret)
    assert on_disk =~
             "def sts_signing_secret, do: Application.get_env(:smalt, :sts_signing_secret)"
  end

  @tag :replay_identity
  test "census is closed at 47 keys; coverage and bijection gates hold" do
    %{out: out, path: out_path} = run_mix(gate_script())

    assert out =~ "GATES_OK"

    assert %{"census" => 47, "coverage" => cov, "bijection" => 0} =
             out_path |> File.read!() |> Jason.decode!()

    assert cov >= 1
  end

  @tag :replay_identity
  test "pack lock digest matches the live pack checkout" do
    %{out: out, path: out_path} = run_mix(gate_script())

    assert out =~ "LOCK_OK"

    [live, locked] =
      out_path |> File.read!() |> Jason.decode!() |> Map.fetch!("lock") |> String.split(" ")

    assert live == locked, """
    :lock_drift - ggen_igniter.pack.lock pins #{locked}, live pack computes #{live}.
    Re-pin: mix ggen_igniter.pack.lock --path #{@pack_dir} --pack smalt-substrate-pack
    """
  end

  defp replay_script do
    """
    alias GgenIgniter.{Ontology, Render, Engine.Graphlaw}
    pack = "#{@pack_dir}"
    graph = Ontology.load!(pack <> "/ontology.ttl")
    ctx = Graphlaw.prepare!(graph, [])
    rows = Graphlaw.run(ctx, File.read!(pack <> "/queries/config_keys.rq"))
    bindings = Mix.Tasks.GgenIgniter.Sync.build_bindings([{"config_keys", rows}])
    out = Render.render(File.read!(pack <> "/templates/config.ex.eex"), bindings)
    out_path = System.get_env("SMALT_REPLAY_OUT") || raise("SMALT_REPLAY_OUT not set")
    File.write!(out_path, out)
    IO.puts("RENDER_OK " <> Integer.to_string(byte_size(out)))
    """
  end

  defp gate_script do
    """
    alias GgenIgniter.{Ontology, Engine.Graphlaw}
    pack = "#{@pack_dir}"
    graph = Ontology.load!(pack <> "/ontology.ttl")
    ctx = Graphlaw.prepare!(graph, [])
    n = length(Graphlaw.run(ctx, File.read!(pack <> "/queries/config_keys.rq")))
    cov = length(Graphlaw.run(ctx, File.read!(pack <> "/gates/config_coverage.rq")))
    bij = length(Graphlaw.run(ctx, File.read!(pack <> "/verify/config-bijection-full.unbound.rq")))
    live = GgenIgniter.PackLock.digest(pack)
    {:ok, body} = File.read("#{@lock_file}")
    %{"packs" => %{"smalt-substrate-pack" => %{"sha256" => locked}}} = Jason.decode!(body)
    File.write!(System.get_env("SMALT_REPLAY_OUT"), Jason.encode!(%{"census" => n, "coverage" => cov, "bijection" => bij, "lock" => live <> " " <> locked}))
    IO.puts("GATES_OK census=\#{n} coverage=\#{cov} bijection=\#{bij}")
    IO.puts("LOCK_OK")
    """
  end

  defp run_mix(script) do
    out_path =
      Path.join(
        root(),
        "tmp/replay-config-" <> Integer.to_string(System.unique_integer([:positive])) <> ".ex"
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
