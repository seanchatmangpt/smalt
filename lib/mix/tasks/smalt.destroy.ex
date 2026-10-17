defmodule Mix.Tasks.Smalt.Destroy do
  @shortdoc "In-process reverse-topological destroy of a fixture's resources"

  @moduledoc """
  Parses the HCL fixture, re-applies it in-process to recover the live ids,
  then runs `Smalt.Enclave.State.destroy/1` — the reverse-topological
  DELETE walk through the real ARM router with 404 verification per id —
  and asserts zero residue (exit 1 on any survivor).

  ## Usage

      mix smalt.destroy --fixture test/terraform_fixture

  Exits 0 on clean destroy, 1 on destroy/residue failure.
  """

  use Mix.Task

  alias Mix.Tasks.Smalt.EnclaveCommon
  alias Smalt.Enclave.{Engine, Hcl, State}

  @switches [fixture: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      "--help" in args or opts[:help] ->
        EnclaveCommon.help!(@moduledoc)

      invalid != [] or argv != [] ->
        EnclaveCommon.fail!(":bad_args task=smalt.destroy invalid=#{inspect(invalid)} argv=#{inspect(argv)}")

      true ->
        main(opts)
    end
  end

  defp main(opts) do
    fixture =
      opts
      |> EnclaveCommon.require_flag!(:fixture, "smalt.destroy")
      |> EnclaveCommon.resolve_fixture()
    EnclaveCommon.ensure_store!()
    # Dev-loop CLI: anonymous router face (same as the ExUnit suite).
    Application.put_env(:smalt, :auth_mode, :anonymous)

    with {:ok, doc} <- Hcl.parse(fixture),
         terms = to_terms(doc),
         {:ok, outcomes} <- Engine.apply(terms, []),
         %{deleted: deleted, residue: residue} <- State.destroy(outcome_map(outcomes)) do
      case nonempty_residue(residue) do
        [] ->
          Mix.shell().info("[destroy] OK fixture=#{fixture} deleted=#{length(deleted)} residue=0")

        survivors ->
          EnclaveCommon.fail!(":residue_nonzero fixture=#{fixture} survivors=#{inspect(survivors, limit: 20)}")
      end
    else
      {:error, reason} ->
        EnclaveCommon.fail!(":destroy_failed fixture=#{fixture} reason=#{inspect(reason, limit: 20)}")
    end
  end

  defp nonempty_residue(residue),
    do: for({t, keys} <- residue, keys != [], do: {t, keys})

  defp to_terms(doc) do
    for r <- doc.resources do
      %{type: r.type, label: r.type <> "." <> r.name, attrs: r.attrs}
    end
  end

  defp outcome_map(outcomes),
    do: Map.new(outcomes, &{&1.label, %{id: &1.id, type: &1.arm_type}})
end
