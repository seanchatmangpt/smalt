defmodule Mix.Tasks.Smalt.AuditResidue do
  @shortdoc "Audit resource-bearing Store tables for post-destroy residue"

  @moduledoc """
  Reads the live residue map (every resource-bearing Store table -> its
  keys) through the real `Smalt.Enclave.State` machinery and asserts it is
  zero when `--strict` is passed.

  ## Usage

      mix smalt.audit_residue [--strict]

  With `--strict`: exit 0 iff zero residue, exit 1 naming the surviving
  tables. Without it: report-only, always exit 0 (unless substrate boot
  fails).
  """

  use Mix.Task

  alias Mix.Tasks.Smalt.EnclaveCommon
  alias Smalt.Enclave.State

  @switches [strict: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      "--help" in args or opts[:help] ->
        EnclaveCommon.help!(@moduledoc)

      invalid != [] or argv != [] ->
        EnclaveCommon.fail!(":bad_args task=smalt.audit_residue invalid=#{inspect(invalid)} argv=#{inspect(argv)}")

      true ->
        main(opts)
    end
  end

  defp main(opts) do
    EnclaveCommon.ensure_store!()

    # destroy/1 with an empty outcome deletes nothing and returns the live
    # residue map — the exact same computation the lifecycle's residue
    # stage asserts on. Reuse, not re-derivation.
    %{residue: residue} = State.destroy(%{})

    for {table, keys} <- Enum.sort(residue) do
      Mix.shell().info("[audit_residue] table=#{table} keys=#{length(keys)}")
    end

    case for({t, keys} <- residue, keys != [], do: {t, keys}) do
      [] ->
        Mix.shell().info("[audit_residue] residue=0")

      survivors ->
        for {t, keys} <- Enum.sort(survivors) do
          IO.puts(
            :stderr,
            "[smalt] ERROR :residue_nonzero severity=BLOCKING_GATE " <>
              "code=ORPHANED_DATA_PLANE_ROWS_DETECTED table=#{t} keys=#{inspect(keys, limit: 10)}"
          )
        end

        if opts[:strict] do
          EnclaveCommon.fail!(":residue_nonzero strict=true survivors=#{length(survivors)}")
        end
    end
  end
end
