defmodule Mix.Tasks.Smalt.Aoq.NifGate do
  @shortdoc "Fails nonzero unless the AoQ QUIC NIF dylib is staged and loaded"

  @moduledoc """
  Presence gate for the AoQ QUIC NIF (FNOX-SJ-QUIC-5).

  The loader in `:cgap_beam` returns `:ok` even when the dylib is missing
  (loud-skip law), so nothing else fails a release without the artifact.
  This task is the fail-closed witness.

      mix smalt.aoq.nif_gate           # check only
      mix smalt.aoq.nif_gate --build   # run scripts/build_aoq_nif.sh first

  Prints `loaded=true` and exits 0 only when a staged `priv/aoq/aq_beam_nif*`
  artifact exists AND `Smalt.Aoq.Quic.Nif.loaded?/0` is true. Otherwise prints
  `loaded=false` with the reason and exits 1.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [build: :boolean])

    if opts[:build], do: build!()

    Mix.Task.run("compile")

    artifacts = Path.wildcard(Path.join(["priv", "aoq", "aq_beam_nif*"]))
    status = Smalt.Aoq.Quic.Nif.load_status()

    cond do
      artifacts == [] ->
        fail("artifact_absent priv/aoq/aq_beam_nif* status=#{inspect(status)}")

      not Smalt.Aoq.Quic.Nif.loaded?() ->
        fail("status=#{inspect(status)} artifacts=#{inspect(artifacts)}")

      true ->
        Mix.shell().info("loaded=true artifacts=#{inspect(artifacts)} status=#{inspect(status)}")
    end
  end

  defp build! do
    script = Path.join(["scripts", "build_aoq_nif.sh"])

    case System.cmd("bash", [script], into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> fail("build_aoq_nif.sh exited #{code}")
    end
  end

  defp fail(reason) do
    Mix.shell().error("loaded=false #{reason}")
    IO.puts("loaded=false #{reason}")
    exit({:shutdown, 1})
  end
end
