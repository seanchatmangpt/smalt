defmodule Mix.Tasks.Smalt.Export do
  @shortdoc "Export the provisioned :smalt_resources graph as IaC (bicep | terraform)"

  @moduledoc """
  Renders the provisioned resource graph (the `:smalt_resources` Store
  table) as IaC via ONE projection pass
  (`Smalt.DataPlane.IacExport.intermediate_model/1`) and a per-format
  renderer — the two formats can never disagree because both consume the
  same intermediate model.

  ## Usage

      mix smalt.export --format bicep      # writes <out>/main.bicep
      mix smalt.export --format terraform  # writes <out>/main.tf + <out>/terraform.tfvars

  ## Options

    * `--format` — `bicep` or `terraform` (required; any other value is a
      typed refusal)
    * `--out` — output directory (default `tmp/export`)

  Exits 0 on success, 1 on bad args / unknown format / a malformed Store row
  (the export refuses typed rather than rendering a partial template).
  """

  use Mix.Task

  alias Mix.Tasks.Smalt.EnclaveCommon
  alias Smalt.DataPlane.IacExport

  @switches [format: :string, out: :string]
  @formats ~w(bicep terraform)
  @default_out "tmp/export"

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      "--help" in args or opts[:help] ->
        EnclaveCommon.help!(@moduledoc)

      invalid != [] or argv != [] ->
        EnclaveCommon.fail!(
          ":bad_args task=smalt.export invalid=#{inspect(invalid)} argv=#{inspect(argv)}"
        )

      true ->
        export(opts)
    end
  end

  defp export(opts) do
    format = EnclaveCommon.require_flag!(opts, :format, "smalt.export")
    out = opts[:out] || @default_out

    case String.downcase(format) do
      known when known in @formats ->
        EnclaveCommon.ensure_store!()

        model =
          case IacExport.intermediate_model() do
            {:ok, model} ->
              model

            {:error, reason} ->
              EnclaveCommon.fail!(
                ":export_failed task=smalt.export reason=#{inspect(reason, limit: 20)}"
              )
          end

        files =
          case known do
            "bicep" -> IacExport.render_bicep(model)
            "terraform" -> IacExport.render_terraform(model)
          end

        Enum.each(files, fn {file, body} ->
          path = Path.join(out, file)
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
        end)

        Mix.shell().info(
          "[export] OK format=#{known} out=#{out} files=#{Enum.join(Map.keys(files), ",")} " <>
            "resources=#{length(model.resources)}"
        )

      other ->
        EnclaveCommon.fail!(
          ":unknown_format task=smalt.export format=#{other} known=#{Enum.join(@formats, "|")}"
        )
    end
  end
end
