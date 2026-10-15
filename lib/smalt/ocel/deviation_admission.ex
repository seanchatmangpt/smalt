defmodule Smalt.Ocel.DeviationAdmission do
  @moduledoc """
  Durable admission of a conformance deviation: a
  `Smalt.Ocel.Conformance.check_trace/3` result with `conforms: false`
  appends ONE JSON line to `tmp/ocel/deviations.jsonl` — a real, durable
  file mutation, replayable as a court fixture (each line is a
  self-contained JSON record; re-running conformance over the recorded
  trace reproduces the verdict).

  When `conforms` is true there is nothing to admit: `{:ok, :conforms}`.
  A `conforms: false` result with an empty `deviations` list is a
  contract violation refused with `{:error, :no_deviation}`.
  """

  @default_path Path.join(["tmp", "ocel", "deviations.jsonl"])

  @type conformance_result :: %{
          optional(atom()) => term(),
          conforms: boolean(),
          fitness: float(),
          deviations: [[String.t()]]
        }

  @doc "Default deviation ledger path (`tmp/ocel/deviations.jsonl`)."
  def default_path, do: @default_path

  @doc """
  Admits one deviation record for a `conforms: false` result. The
  deviating move is taken from the FIRST entry of the real `deviations`
  list — never invented. Returns `{:ok, record_id}` on write,
  `{:ok, :conforms}` when nothing deviated, `{:error, :no_deviation}` on
  the contract violation, `{:error, {:write_failed, reason}}` on real
  I/O failure.

  Options: `:path` (default `tmp/ocel/deviations.jsonl`), `:trace`
  (the replayable trace — recorded when given), `:reference_trace_id`,
  `:candidate_trace_id`.
  """
  @spec admit(conformance_result(), keyword()) ::
          {:ok, String.t()} | {:ok, :conforms} | {:error, term()}
  def admit(result, opts \\ [])

  def admit(%{conforms: true}, _opts), do: {:ok, :conforms}

  def admit(%{conforms: false, deviations: []}, _opts), do: {:error, :no_deviation}

  def admit(%{conforms: false, deviations: [[log_side, model_side] | _]} = result, opts) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    deviating_move = "#{log_side}/#{model_side}"
    reference = Keyword.get(opts, :reference_trace_id, "reference")
    candidate = Keyword.get(opts, :candidate_trace_id, "candidate")

    record_id =
      "ocel_deviation_" <>
        (:crypto.hash(:sha256, reference <> candidate <> deviating_move <> timestamp)
         |> Base.encode16(case: :lower)
         |> binary_part(0, 16))

    record = %{
      "id" => record_id,
      "referenceTraceId" => reference,
      "candidateTraceId" => candidate,
      "deviatingMove" => deviating_move,
      "fitness" => Map.get(result, :fitness),
      "trace" => Keyword.get(opts, :trace),
      "timestamp" => timestamp,
      "status" => "observed"
    }

    path = Keyword.get(opts, :path, @default_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(record) <> "\n", [:append]) do
      {:ok, record_id}
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  @doc "Reads back every admitted deviation record from `path` (court fixture replay)."
  @spec read_all(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_all(path \\ @default_path) do
    case File.read(path) do
      {:ok, body} ->
        records =
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        {:ok, records}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end
end
