defmodule Mix.Tasks.Smalt.Apply do
  @shortdoc "In-process enclave apply: HCL fixture -> ARM router -> tfstate JSON"

  @moduledoc """
  Parses the HCL fixture, applies it in-process through the real ARM
  gateway router (no sockets, no terraform binary), and writes the
  terraform.tfstate-shaped read-projection to `--output`.

  ## Usage

      mix smalt.apply --fixture test/terraform_fixture --output tmp/state.tfstate

  Exits 0 on success, 1 on parse/apply/write failure.
  """

  use Mix.Task

  alias Mix.Tasks.Smalt.EnclaveCommon
  alias Smalt.Enclave.{Engine, Hcl, State}

  @switches [fixture: :string, output: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      "--help" in args or opts[:help] ->
        EnclaveCommon.help!(@moduledoc)

      invalid != [] or argv != [] ->
        EnclaveCommon.fail!(":bad_args task=smalt.apply invalid=#{inspect(invalid)} argv=#{inspect(argv)}")

      true ->
        main(opts)
    end
  end

  defp main(opts) do
    fixture =
      opts
      |> EnclaveCommon.require_flag!(:fixture, "smalt.apply")
      |> EnclaveCommon.resolve_fixture()
    output = EnclaveCommon.require_flag!(opts, :output, "smalt.apply")
    EnclaveCommon.ensure_store!()

    # Dev-loop CLI: anonymous router face (same as the ExUnit suite) —
    # SCOPED via MixAuthScope so the process-global flip restores on exit
    # (success, failure, or raise).
    Smalt.MixAuthScope.with_anonymous_auth(fn ->
      with {:ok, doc} <- Hcl.parse(fixture),
           terms = to_terms(doc),
           {:ok, outcomes} <- Engine.apply(terms, []) do
        State.write(outcome_map(outcomes), output)
        Mix.shell().info("[apply] OK fixture=#{fixture} output=#{output} resources=#{length(outcomes)}")
      else
        {:error, reason} ->
          EnclaveCommon.fail!(":apply_failed fixture=#{fixture} reason=#{inspect(reason, limit: 20)}")
      end
    end)
  end

  # Same shapes as the lifecycle: TF per-type local names -> type-qualified
  # "type.name" engine labels; State terms carry the ARM type.
  defp to_terms(doc) do
    for r <- doc.resources do
      %{type: r.type, label: r.type <> "." <> r.name, attrs: r.attrs}
    end
  end

  defp outcome_map(outcomes),
    do: Map.new(outcomes, &{&1.label, %{id: &1.id, type: &1.arm_type}})
end
