defmodule Mix.Tasks.Smalt.NativeLadder do
  @shortdoc "In-process enclave lifecycle ladder: parse -> apply -> plan -> synthesize -> destroy -> residue"

  @moduledoc """
  Runs `Smalt.Enclave.Lifecycle.run/2` against an HCL fixture: parse ->
  in-process engine apply -> zero-drift plan -> tfstate synthesis ->
  reverse-topo destroy -> zero-residue assert, printing one row per stage.

  ## Usage

      mix smalt.native_ladder --fixture test/terraform_fixture [--timeout <ms>] [--output <tfstate>]

  Exits 0 green, 1 on any stage failure. No sockets, no ports, no terraform
  binary — every hop is a plain function call.
  """

  use Mix.Task

  alias Mix.Tasks.Smalt.EnclaveCommon

  @switches [fixture: :string, timeout: :integer, output: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      "--help" in args or opts[:help] ->
        EnclaveCommon.help!(@moduledoc)

      invalid != [] or argv != [] ->
        EnclaveCommon.fail!(
          ":bad_args task=smalt.native_ladder invalid=#{inspect(invalid)} argv=#{inspect(argv)}"
        )

      true ->
        main(opts)
    end
  end

  defp main(opts) do
    fixture =
      opts
      |> EnclaveCommon.require_flag!(:fixture, "smalt.native_ladder")
      |> EnclaveCommon.resolve_fixture()

    timeout_ms = Keyword.get(opts, :timeout, 60_000)
    EnclaveCommon.ensure_store!()

    t0 = System.monotonic_time(:millisecond)

    runner =
      Task.async(fn ->
        # Local in-process ladder: the substrate's default :enforce auth
        # mode gates the router, but this task is a dev loop tool that
        # never crosses a socket — run it against the anonymous face, the
        # same face the ExUnit suite uses (config/test.exs). SCOPED via
        # MixAuthScope so the flip restores when the task body exits.
        Smalt.MixAuthScope.with_anonymous_auth(fn ->
          lifecycle_opts =
            case Keyword.fetch(opts, :output) do
              {:ok, path} -> [state_path: path]
              :error -> []
            end

          Smalt.Enclave.Lifecycle.run(fixture, lifecycle_opts)
        end)
      end)

    case Task.await(runner, timeout_ms) do
      {:ok, report} ->
        print_rows(report, System.monotonic_time(:millisecond) - t0)
        Mix.shell().info("[ladder] OK fixture=#{fixture} state=#{report.state_path}")

      {:error, {:stage_failed, stage, reason}} ->
        print_rows(%{}, 0)
        EnclaveCommon.fail!(":stage_failed stage=#{stage} reason=#{inspect(reason, limit: 20)}")
    end
  end

  defp print_rows(report, total_ms) do
    stages = [:parse, :apply, :plan, :synthesize, :destroy, :residue]
    timings = Map.get(report, :timings_ms, %{})

    for stage <- stages do
      ms = Map.get(timings, stage)
      status = if is_integer(ms), do: "ok", else: "n/a"
      ms_text = if is_integer(ms), do: to_string(ms), else: "-"
      Mix.shell().info("[ladder] stage=#{stage} status=#{status} ms=#{ms_text}")
    end

    Mix.shell().info("[ladder] total_ms=#{total_ms}")
  end
end
