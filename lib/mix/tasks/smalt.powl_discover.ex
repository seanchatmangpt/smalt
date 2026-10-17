defmodule Mix.Tasks.Smalt.PowlDiscover do
  @shortdoc "Discover the OCEL golden path via the ex4pm file-level bridge"
  @moduledoc """
  Runs `Smalt.Ocel.Revops.PowlBridge.discover/2` over the smalt OCEL
  NDJSON sink and writes the discovered DFG golden-path model.

      mix smalt.powl_discover [log.ndjson] [--object-type enclave] [--model-out path]

  `conform` checks a NEW run's log against the discovered model:

      mix smalt.powl_discover conform [log.ndjson] [--model-path path] [--object-type enclave]

  Exit 0 on a receipted run; exit 1 on any refusal or script failure
  (fail-closed — a bridge that cannot flip is FAIL, not PASS).
  """

  use Mix.Task

  alias Smalt.Ocel.Revops.PowlBridge

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv} =
      OptionParser.parse!(args,
        strict: [object_type: :string, model_out: :string, model_path: :string, via: :string],
        aliases: [t: :string]
      )

    kwopts = Keyword.take(opts, [:object_type, :model_out, :model_path, :via])

    case argv do
      ["conform" | rest] ->
        path = List.first(rest) || PowlBridge.default_log_path()
        kwopts = Keyword.put(kwopts, :model_path, kwopts[:model_path] || default_model())

        case PowlBridge.conform(path, kwopts) do
          {:ok, report} ->
            Mix.shell().info(Jason.encode!(render(report), pretty: true) <> "\n")
            Mix.shell().info("CONFORM ok: fitness=#{fitness(report)}")

          {:error, reason} ->
            Mix.shell().error("conform FAILED: #{inspect(reason, limit: 10)}")
            exit({:shutdown, 1})
        end

      [path] ->
        path = path || PowlBridge.default_log_path()

        case PowlBridge.discover(path, kwopts) do
          {:ok, report} ->
            Mix.shell().info(Jason.encode!(render(report), pretty: true) <> "\n")
            Mix.shell().info("DISCOVER ok: standing=#{standing(report)}")

          {:error, reason} ->
            Mix.shell().error("discover FAILED: #{inspect(reason, limit: 10)}")
            exit({:shutdown, 1})
        end

      [] ->
        path = PowlBridge.default_log_path()
        kwopts = Keyword.put(kwopts, :model_out, kwopts[:model_out] || default_model())

        case PowlBridge.discover(path, kwopts) do
          {:ok, report} ->
            Mix.shell().info(Jason.encode!(render(report), pretty: true) <> "\n")
            Mix.shell().info("DISCOVER ok: standing=#{standing(report)}")

          {:error, reason} ->
            Mix.shell().error("discover FAILED: #{inspect(reason, limit: 10)}")
            exit({:shutdown, 1})
        end

      other ->
        Mix.shell().error(
          "usage: mix smalt.powl_discover [-- conform] [log.ndjson] [opts]; got: #{inspect(other)}"
        )

        exit({:shutdown, 2})
    end
  end

  defp default_model, do: Path.join("tmp/ocel", "powl_model.json")

  # Script face reports are decoded JSON (string keys); in-process reports
  # are atom-keyed maps carrying the live POWL model struct.
  defp render(report) when is_map(report) do
    if is_map_key(report, :model) do
      %{
        "standing" => report.standing,
        "subject_hash" => report.subject_hash,
        "receipt_hash" => report.receipt_hash,
        "model_summary" => model_summary(report.model)
      }
    else
      report
    end
  end

  defp render(other), do: other

  defp model_summary(%{type: :dfg, edges: edges, activities: activities} = _model) do
    %{kind: "dfg", activity_count: map_size(activities), edge_count: map_size(edges)}
  end

  defp model_summary(model) when is_struct(model), do: %{kind: to_string(model.__struct__)}

  defp model_summary(_), do: %{kind: "unknown"}

  defp fitness(report), do: Map.get(report, :fitness) || report["fitness"]
  defp standing(report), do: inspect(Map.get(report, :standing) || report["standing"])
end
