defmodule Smalt.Projection.Admission do
  @moduledoc """
  EA-style admission projection: ONE typed record stream (the admission
  matrix) composing every smalt admission surface — GraphLaw shape verdicts
  (`Smalt.GraphLaw.Validator`), Secure Key Release admission
  (`Smalt.DataPlane.SKR`), bearer auth refusals (`Smalt.Auth.Bearer`) and
  ledger deviation admission (`Smalt.Ocel.DeviationAdmission`) — into rows
  of `who / what / verdict / standing`.

  ## Provenance

  Standing vocabulary is adapted from the ea-projection-admission-pack
  ontology (`eap:Standing` = UNKNOWN | CANDIDATE | ADMITTED | QUALIFIED |
  ALIVE, prefix adapted to the smalt admission surface; see
  `docs/PACK_INTEGRATION/ea-projection.md`). The record shape mirrors the
  projection-matrix-compose pack's `elixir-binding.ex.tmpl` projection map
  (subject/consumer/adapter), re-keyed for admission events.

  ## Mount

  Read-side composition only — producers are never edited:

    * `attach/0` — a `:telemetry` handler over `[:smalt, :admit]` /
      `[:smalt, :refuse]` writes one matrix row per event.
    * `seed/3` — family adapters project the REAL verdict tuples returned
      by each surface (no re-derivation).
    * `from_store/0` — projects the durable deviation ledger
      (`tmp/ocel/deviations.jsonl`) into matrix rows.

  ## Matter-isolation law (privacy)

  Matrix rows carry family, subject strings and typed codes/verdicts only —
  never payload values or secrets. This matches the `Smalt.Telemetry`
  matter-isolation contract (metadata keys `event/verdict/code/route` only).
  """

  alias Smalt.Ocel.DeviationAdmission
  alias Smalt.Projection.Identity
  alias Smalt.Store

  @table :smalt_admission_matrix
  @handler_id "smalt-admission-projection"

  @families [:graphlaw, :skr, :auth, :ledger_deviation, :smalt_event]
  @standings [:unknown, :candidate, :admitted, :qualified, :alive]

  @enforce_keys [:id, :family, :subject, :verdict, :standing]
  defstruct [:id, :family, :subject, :verdict, :standing, :code, :timestamp]

  @typedoc "Admission family."
  @type family :: :graphlaw | :skr | :auth | :ledger_deviation | :smalt_event

  @typedoc """
  Standing, adapted from the ea-projection-admission-pack `eap:Standing`
  vocabulary (UNKNOWN | CANDIDATE | ADMITTED | QUALIFIED | ALIVE).
  """
  @type standing :: :unknown | :candidate | :admitted | :qualified | :alive

  @typedoc "Verdict: admit, refuse, or the deviation-record kind."
  @type verdict :: :admit | :refuse | :deviation

  @typedoc "One typed matrix record (who/what = family+subject, verdict+standing)."
  @type record :: %__MODULE__{
          id: String.t(),
          family: family(),
          subject: String.t(),
          verdict: verdict(),
          standing: standing(),
          code: atom() | String.t() | nil,
          timestamp: String.t()
        }

  @doc "Admission families the projection composes."
  def families, do: @families

  @doc "Standing vocabulary (adapted from `eap:Standing`)."
  def standings, do: @standings

  @doc """
  Attaches the telemetry handler over `[:smalt, :admit]` / `[:smalt, :refuse]`.
  Idempotent; returns `:ok`.
  """
  @spec attach() :: :ok
  def attach do
    ensure_table()

    case :telemetry.attach_many(
           @handler_id,
           [[:smalt, :admit], [:smalt, :refuse]],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:smalt, event], _measurements, metadata, _config)
      when event in [:admit, :refuse] do
    ensure_table()
    verdict = if event == :admit, do: :admit, else: :refuse
    head = Map.get(metadata, :verdict) || Map.get(metadata, :code)
    subject = Map.get(metadata, :route) || "(no-route)"

    row = %__MODULE__{
      id: row_id(:smalt_event),
      family: :smalt_event,
      subject: subject,
      verdict: verdict,
      standing: standing_for_verdict(verdict),
      code: head,
      timestamp: timestamp()
    }

    Store.put(@table, row.id, row)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Projects a REAL verdict tuple from one admission surface into the matrix:

      seed(:graphlaw, "Microsoft.Compute/virtualMachines", {:ok})
      seed(:skr, "my-key", {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}})
      seed(:auth, "/egress/x", {:refuse, "AuthenticationFailed", "MissingBearerToken"})
      seed(:ledger_deviation, "reference/candidate", {:ok, "ocel_deviation_..."})

  Returns the inserted `t:record/0`.
  """
  @spec seed(family(), String.t(), term()) :: record()
  def seed(family, subject, raw_verdict)
      when family in @families and is_binary(subject) and family != :smalt_event do
    ensure_table()
    {verdict, standing, code} = normalize(family, raw_verdict)

    row = %__MODULE__{
      id: row_id(family),
      family: family,
      subject: subject,
      verdict: verdict,
      standing: standing,
      code: code,
      timestamp: timestamp()
    }

    Store.put(@table, row.id, row)
    row
  end

  @doc """
  Projects every durable ledger deviation record
  (`Smalt.Ocel.DeviationAdmission.read_all/1`) into the matrix. Idempotent
  per record: rows are keyed by the deviation record `id`, so re-reading the
  same ledger does not duplicate rows.

  A malformed (non-JSON) ledger line is a boundary crash class already fixed
  in `Smalt.Projection.SemanticEpoch.timeline/1`; this adapter refuses it as
  a typed ArgumentError naming the path — never the raw Jason.DecodeError
  escape.
  """
  @spec from_store(String.t()) :: [record()]
  def from_store(path \\ DeviationAdmission.default_path()) do
    ensure_table()

    DeviationAdmission.read_all(path)
    |> case do
      {:ok, records} ->
        # Lens-2 cycle 5: a hand-tampered ledger record without a binary
        # id crashed from_store ("arg" <> nil -> ArgumentError). Same
        # identity-vacuity class as SemanticEpoch cycle 2 — refuse typed.
        case refuse_degenerate_ids(records, path) do
          :ok ->
            Enum.map(records, fn rec ->
            row = %__MODULE__{
              id: "ledger_deviation:" <> rec["id"],
            family: :ledger_deviation,
            subject: "#{rec["referenceTraceId"]}/#{rec["candidateTraceId"]}",
            verdict: :deviation,
            standing: :admitted,
            code: rec["deviatingMove"],
            timestamp: rec["timestamp"]
          }

          Store.put(@table, row.id, row)
          row
        end)

          bad ->
            raise ArgumentError,
                  "malformed deviation ledger at #{inspect(path)}: " <>
                    "malformed_ledger_identity #{inspect(bad)}"
        end

      {:error, reason} ->
        raise ArgumentError,
              "cannot read deviation ledger at #{inspect(path)}: #{inspect(reason)}"
    end
  rescue
    e in Jason.DecodeError ->
      raise ArgumentError,
            "malformed deviation ledger at #{inspect(path)}: #{Exception.message(e)}"
  end

  # Lens-2 cycle 5: identity fence for tampered ledger records (see
  # from_store/1). Lens-3 cycle 1: the empty string IS a binary — it passed
  # the fence and two blank-id records then BOTH mapped to row key
  # "ledger_deviation:"; the second silently overwrote the first in the
  # matrix (measured: stored_rows=[{"ledger_deviation:", "move_b"}], row
  # "move_a" lost). A blank binary carries zero identity bits; refuse it on
  # the same malformed_ledger_identity axis.
  #
  # Lens-3 cycle 3: duplicate NON-blank ids hit the same key collision —
  # measured: from_store returned 2 rows but the matrix stored only the
  # last ("move_b"); the first admission was silently lost. A ledger with
  # two records of one id is a degenerate identity space; refuse typed.
  @spec refuse_degenerate_ids([map()], String.t()) :: :ok | {:error, term()}
  defp refuse_degenerate_ids(records, path) do
    # Lens-5 cycle 4: a non-map ledger "record" (a valid-JSON array/string
    # line through the producer boundary) previously crashed from_store out
    # of Access on `& &1["id"]` — refuse typed on the existing
    # malformed-ledger axis instead, never a crash.
    case Enum.find(records, fn rec -> not is_map(rec) end) do
      nil ->
        ids = Enum.map(records, & &1["id"])

        # NOTE: the vacuous id may itself be nil, so Enum.find/2 (which returns
        # the element) cannot distinguish "found nil" from "not found" — the
        # lens-3 cycle-3 fence-bug regression. Walk indexed tuples instead.
        # Lens-4 cycle 1: identity?/1 generalizes to Smalt.Projection.Identity
        # (whitespace-only / invisible-format-only ids carry zero visible
        # identity bits; they projected as PK "ledger_deviation:  " etc.).
        case Enum.find(Enum.with_index(ids), fn {id, _} -> not Identity.valid?(id) end) do
          nil ->
            case find_dup(ids) do
              nil -> :ok
              dup -> {:error, {:duplicate_ledger_identity, path, dup}}
            end

          {bad, _i} ->
            {:error, {:malformed_ledger_identity, path, bad}}
        end

      bad ->
        {:error, {:malformed_ledger_record, path, bad}}
    end
  end

  defp find_dup(ids) do
    ids
    |> Enum.reduce_while({:ok, MapSet.new()}, fn id, {:ok, seen} ->
      if MapSet.member?(seen, id),
        do: {:halt, {:dup, id}},
        else: {:cont, {:ok, MapSet.put(seen, id)}}
    end)
    |> case do
      {:dup, id} -> id
      {:ok, _} -> nil
    end
  end

  @doc "All matrix rows in insertion (key) order."
  @spec matrix() :: [record()]
  def matrix do
    ensure_table()
    @table
    |> Store.keys()
    |> Enum.flat_map(fn key ->
      case :ets.lookup(@table, key) do
        [{^key, %__MODULE__{} = row}] -> [row]
        _ -> []
      end
    end)
  end

  @doc "Aggregated verdict counters: `%{{family, verdict} => n}`."
  @spec counts() :: %{{family(), verdict()} => non_neg_integer()}
  def counts do
    Enum.frequencies_by(matrix(), &{&1.family, &1.verdict})
  end

  @doc "Deletes every projection-owned row (test isolation)."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    Enum.each(Store.keys(@table), &:ets.delete(@table, &1))
    :ok
  end

  # -- internals --------------------------------------------------------------

  # The projection owns its table (not in Smalt.Store @tables — the store
  # module is producer-owned); create it lazily, idempotently. Two defect
  # classes closed here (lens-2 cycle 3):
  #
  #   * creation race: handle_event/4 fires concurrently in producer
  #     processes — two callers can both see :undefined and both :ets.new;
  #     the loser raised ArgumentError. A lost :ets.new now folds to :ok
  #     (the winner's table stands).
  #   * owner-exit loss: the table was owned by whichever transient process
  #     created it — when that process exited, the WHOLE admission matrix
  #     was silently deleted. The Store GenServer (permanent wherever the
  #     projection is used) is the heir, so the table survives its creator.
  defp ensure_table do
    if :ets.info(@table) == :undefined do
      opts =
        case Process.whereis(Store) do
          nil -> [:ordered_set, :public, :named_table, write_concurrency: true]
          owner -> [:ordered_set, :public, :named_table, write_concurrency: true, heir: owner]
        end

      :ets.new(@table, opts)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Family adapters: real verdict tuples in, typed (verdict, standing, code) out.
  defp normalize(:graphlaw, verdict) when verdict in [:ok, {:ok}],
    do: {:admit, :admitted, nil}

  defp normalize(:graphlaw, {:invalid, violations}) do
    {:refuse, :unknown, code_from_violations(violations)}
  end

  defp normalize(:graphlaw, {:refused, reason}), do: {:refuse, :unknown, reason}

  defp normalize(:skr, {:ok, 200, _body}), do: {:admit, :admitted, nil}

  defp normalize(:skr, {:error, status, body}) do
    code =
      case body do
        %{"error" => %{"code" => c}} -> c
        _ -> status
      end

    {:refuse, :unknown, code}
  end

  defp normalize(:auth, :ok), do: {:admit, :admitted, nil}
  defp normalize(:auth, {:refuse, code, _reason}), do: {:refuse, :unknown, code}

  defp normalize(:ledger_deviation, {:ok, :conforms}), do: {:admit, :admitted, nil}
  defp normalize(:ledger_deviation, {:ok, _record_id}), do: {:deviation, :admitted, nil}
  defp normalize(:ledger_deviation, {:error, reason}), do: {:refuse, :unknown, reason}

  defp code_from_violations([%{constraint: c} | _]) when is_binary(c), do: c

  defp code_from_violations([%{message: m} | _]) when is_binary(m), do: String.slice(m, 0, 32)

  defp code_from_violations(_), do: :SHAPE_INVALID

  defp standing_for_verdict(:admit), do: :admitted
  defp standing_for_verdict(_), do: :unknown

  defp row_id(family) do
    seq = System.unique_integer([:positive, :monotonic])

    "#{family}:#{seq |> :erlang.integer_to_binary() |> String.pad_leading(20, "0")}"
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
