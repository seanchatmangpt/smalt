defmodule Smalt.Ocel.Revops.PowlBridge do
  @moduledoc """
  smalt -> ex4pm bridge: smalt reads and assembles its OCEL 2.0 NDJSON
  through `Smalt.Telemetry.OcelNdjson.assemble_document/1`, hands the
  assembled OCEL 2.0 document straight to `Ex4pm.ingest/1`, and calls
  `Ex4pm.discover/2` / `Ex4pm.conform/3` as plain in-process function
  calls — ex4pm is a path-dep of smalt, so no subprocess is needed on
  the hot path.

  A file-level script face (`priv/smalt/powl_bridge.exs` in the ex4pm
  checkout, `opts[:via] == :script`) runs the same mining through a
  subprocess `mix run` inside the ex4pm app — the zero-dep transport
  for callers that do not compile ex4pm.

  The discovered model is the BEAM engine's directly-follows golden
  path (per object-type flattening via `Ex4pm.OCEL.flatten/2`); it is
  JSON-round-trippable through `encode_model/1` / `decode_model/1`
  (tuple edge keys <-> `{from,to}` rows) so a later process can conform
  a NEW run's trace against it.

  Paths are env-overridable (`:smalt` app env `:ex4pm_dir`); the script
  face defaults to the sibling checkout `../ex4pm/ex4pm`.
  """

  alias Smalt.Telemetry.OcelNdjson

  @default_dir Path.expand("../ex4pm/ex4pm", File.cwd!())
  @script "priv/smalt/powl_bridge.exs"
  @default_object_type "enclave"
  @build_root "_build-lane430"
  @default_model_path Path.join("tmp/ocel", "powl_model.json")

  @doc "Default OCEL sink log path (`tmp/ocel/events.ndjson`)."
  def default_log_path, do: Path.join(OcelNdjson.default_dir(), "events.ndjson")

  @doc "Default object-type case notion (`#{@default_object_type}`)."
  def default_object_type, do: @default_object_type

  @doc "Default persisted-model path (`tmp/ocel/powl_model.json`)."
  def default_model_path, do: @default_model_path

  @doc """
  Assembles `path` (NDJSON of per-line OCEL 2.0 documents) and maps it to
  the Ex4pm wire shape (type->activity, time->timestamp, relationships ->
  object_ids), writing ONE mapped JSON document. Returns
  `{:ok, %{path: mapped_path, events: n, objects: n}}` or
  `{:error, violations}` (fail-closed assembly, typed violations).
  """
  @spec export_log(String.t(), keyword()) :: {:ok, map()} | {:error, [map()]}
  def export_log(path \\ default_log_path(), opts \\ []) do
    with {:ok, doc} <- OcelNdjson.read_document(path) do
      mapped = map_log(doc)

      out_path = Keyword.get(opts, :out) || default_tmp("powl_input")
      File.write!(out_path, Jason.encode!(mapped))

      {:ok,
       %{path: out_path, events: length(mapped["events"]), objects: length(mapped["objects"])}}
    end
  end

  # In-memory OCEL 2.0 -> Ex4pm raw-shape map (the exact wire shape
  # `Ex4pm.ingest/1` normalizes natively: plain "events"/"objects"/
  # "object_relationships" keys; type->activity, time->timestamp,
  # relationships -> object_ids). Shared by the in-process face
  # (`ingest_log/2`) and the file-level script face (`export_log/2`).
  defp map_log(doc) do
    events =
      for e <- doc["ocel:events"] do
        %{
          "id" => e["id"],
          # OCEL "type" is the activity; stage-qualify events that carry a
          # `stage` attribute so the golden path is the stage ladder
          # (parse->apply->plan->synthesize->destroy->residue), not a
          # one-node degenerate DFG over the bare event type.
          "activity" => activity(e),
          "timestamp" => e["time"],
          "object_ids" => for(r <- e["relationships"] || [], do: r["objectId"]),
          "attributes" => e["attributes"] || %{}
        }
      end

    objects = for o <- doc["ocel:objects"], do: %{"id" => o["id"], "type" => o["type"]}

    %{
      "events" => events,
      "objects" => objects,
      "object_relationships" =>
        for(
          o <- doc["ocel:objects"],
          r <- o["relationships"] || [],
          do: %{
            "source_id" => o["id"],
            "target_id" => r["target_id"],
            "qualifier" => r["qualifier"]
          }
        )
    }
  end

  @doc """
  Discovers the DFG golden path over the OCEL log at `path` for
  `object_type` (default in-process; `opts[:via] == :script` for the
  subprocess face). Returns `{:ok, report}` where the in-process report
  carries `model` (engine DFG map), `standing`, `subject_hash`,
  `receipt_hash`; the script report is the decoded JSON. Persists the
  model to `opts[:model_out]` (default `tmp/ocel/powl_model.json`).
  """
  @spec discover(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover(path, opts \\ []) do
    object_type = Keyword.get(opts, :object_type, @default_object_type)
    model_out = Keyword.get(opts, :model_out) || @default_model_path

    result =
      if opts[:via] == :script do
        discover_script(path, opts, object_type, model_out)
      else
        with {:ok, log} <- ingest_log(path, opts),
             {:ok, run} <- discover_run(log, object_type) do
          File.write!(model_out, Jason.encode!(encode_model(run.value)))

          {:ok,
           %{
             model: run.value,
             standing: run.standing,
             subject_hash: run.subject_hash,
             receipt_hash: receipt_hash(run)
           }}
        end
      end

    case result do
      {:error, _} = err -> err
      {:ok, report} -> {:ok, Map.put(report, :model_path, model_out)}
    end
  end

  @doc """
  Conforms a NEW run's log at `path` against the discovered model
  (source: `opts[:model]` live map > `opts[:model_path]` file >
  default model path). Returns `{:ok, report}` with the DFG conformance
  fitness.
  """
  @spec conform(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def conform(path, opts \\ []) do
    object_type = Keyword.get(opts, :object_type, @default_object_type)

    if opts[:via] == :script do
      conform_script(path, opts, object_type)
    else
      with {:ok, log} <- ingest_log(path, opts),
           {:ok, model} <- fetch_model(opts) do
        case Ex4pm.conform(log, model, object_type: object_type) do
          {:ok, run} ->
            {:ok,
             %{
               fitness: run.value.fitness,
               standing: run.standing,
               subject_hash: run.subject_hash,
               receipt_hash: receipt_hash(run)
             }}

          {:error, refusal} ->
            {:error, {:ex4pm_refused, refusal}}
        end
      end
    end
  end

  @doc """
  JSON-safe DFG encoding: atom/tuple keys become string rows
  (`{a,b}` edge -> `%{"from" => a, "to" => b, ...}`).
  """
  def encode_model(%{type: :dfg} = dfg) do
    %{
      "type" => "dfg",
      "object_type" => dfg.object_type,
      "activities" => dfg.activities,
      "trace_count" => dfg.trace_count,
      "starts" => Map.new(dfg.starts, fn {k, v} -> {to_string(k), v} end),
      "ends" => Map.new(dfg.ends, fn {k, v} -> {to_string(k), v} end),
      "edges" =>
        Enum.sort_by(dfg.edges, fn {{a, b}, _} -> {a, b} end)
        |> Enum.map(fn {{a, b}, meta} ->
          %{
            "from" => a,
            "to" => b,
            "count" => meta.count,
            "average_duration_ms" => meta.average_duration_ms
          }
        end)
    }
  end

  @doc "Rebuilds the engine-shaped DFG (atom/tuple keys) from `encode_model/1` JSON."
  def decode_model(json) when is_map(json) do
    %{
      type: :dfg,
      object_type: json["object_type"],
      activities: json["activities"],
      trace_count: json["trace_count"],
      starts: Map.new(json["starts"] || %{}, fn {k, v} -> {k, v} end),
      ends: Map.new(json["ends"] || %{}, fn {k, v} -> {k, v} end),
      edges:
        Map.new(json["edges"], fn e ->
          {{e["from"], e["to"]},
           %{count: e["count"], average_duration_ms: e["average_duration_ms"]}}
        end)
    }
  end

  # -- in-process ingest ------------------------------------------------------

  defp discover_run(log, object_type) do
    case Ex4pm.discover(log, object_type: object_type) do
      {:ok, run} -> {:ok, run}
      {:error, refusal} -> {:error, {:ex4pm_refused, refusal}}
    end
  end

  # The assembled OCEL 2.0 document is ALREADY a shape `Ex4pm.ingest/1`
  # normalizes natively (ocel:events / ocel:objects) — the mapped JSON
  # export remains the script face's wire format only.
  defp activity(e) do
    case e["attributes"] && e["attributes"]["stage"] do
      nil -> e["type"]
      stage -> e["type"] <> ":" <> to_string(stage)
    end
  end

  defp ingest_log(path, _opts) do
    case OcelNdjson.read_document(path) do
      {:ok, doc} ->
        case Ex4pm.ingest(map_log(doc)) do
          {:ok, log} -> {:ok, log}
          {:error, reason} -> {:error, {:ex4pm_ingest_refused, reason}}
        end

      {:error, violations} ->
        {:error, violations}
    end
  end

  defp fetch_model(opts) do
    cond do
      model = opts[:model] ->
        {:ok, model}

      path = opts[:model_path] ->
        load_model(path)

      true ->
        load_model(@default_model_path)
    end
  end

  defp load_model(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body |> Jason.decode!() |> decode_model()}

      {:error, reason} ->
        {:error, {:no_model, "cannot read model at #{path}: #{inspect(reason)}"}}
    end
  end

  # -- script transport (CLI face) ---------------------------------------------

  # Script face runs `cd:`-ed into the ex4pm checkout — every path handed
  # across the subprocess boundary must be ABSOLUTE or it resolves against
  # the wrong cwd (witnessed: script read tmp/... relative to ex4pm and
  # failed with File.Error).
  defp discover_script(path, opts, object_type, model_out) do
    in_path = Path.expand(model_out <> ".input.json")
    model_out = Path.expand(model_out)

    with {:ok, %{path: in_path}} <-
           export_log(path, Keyword.put(opts, :out, in_path)),
         {_, 0} <- run_script(["discover", in_path, model_out, object_type]) do
      {:ok, model_out |> File.read!() |> Jason.decode!()}
    else
      {:error, violations} -> {:error, violations}
      {output, code} -> {:error, {:script_failed, code, output}}
    end
  end

  defp conform_script(path, opts, object_type) do
    model_path = Path.expand(Keyword.get(opts, :model_path) || @default_model_path)
    out_path = Path.expand(Keyword.get(opts, :out) || default_tmp("powl_conform"))

    with {:ok, %{path: in_path}} <-
           export_log(path, Keyword.put(opts, :out, Path.expand(default_tmp("powl_input")))),
         {_, 0} <- run_script(["conform", in_path, model_path, out_path, object_type]) do
      {:ok,
       out_path
       |> File.read!()
       |> Jason.decode!()
       |> Map.new(fn {k, v} -> {conform_key(k), v} end)}
    end
  end

  # SPOF-B / A-6 (atom law, frame_codec class): the ex4pm conform script's
  # JSON keys are EXTERNAL script output — never mint atoms from unverified
  # input. The previous raw per-key conversion is replaced by this bounded,
  # compile-time allowlist: known keys convert to atoms (byte-identical for
  # consumers — the mix task and the in-process path already read atom keys);
  # any unknown/future script key stays a binary, so a script-side key addition
  # can no longer grow the atom table.
  defp conform_key("fitness"), do: :fitness
  defp conform_key("standing"), do: :standing
  defp conform_key("subject_hash"), do: :subject_hash
  defp conform_key("receipt_hash"), do: :receipt_hash
  defp conform_key("observed_edge_count"), do: :observed_edge_count
  defp conform_key("deviation_count"), do: :deviation_count
  defp conform_key("deviations"), do: :deviations
  defp conform_key("mean_case_fitness_score"), do: :mean_case_fitness_score
  defp conform_key("object_type"), do: :object_type
  defp conform_key(other) when is_binary(other), do: other

  defp run_script(args) do
    dir = ex4pm_dir()
    script = Path.join(dir, @script)

    if File.regular?(script) do
      System.cmd(elixir_bin(), ["-S", "mix", "run", script | args],
        cd: dir,
        env: %{"MIX_BUILD_ROOT" => @build_root},
        stderr_to_stdout: true
      )
    else
      {~s(ex4pm bridge script missing: #{script}), 127}
    end
  end

  defp ex4pm_dir, do: Application.get_env(:smalt, :ex4pm_dir, @default_dir)

  defp elixir_bin, do: System.find_executable("elixir") || "elixir"

  defp default_tmp(prefix) do
    Path.join(OcelNdjson.default_dir(), "#{prefix}-#{System.system_time(:millisecond)}.json")
  end

  defp receipt_hash(run), do: run.receipt && Map.get(run.receipt, :hash)
end
