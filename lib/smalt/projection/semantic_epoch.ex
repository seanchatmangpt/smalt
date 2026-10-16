defmodule Smalt.Projection.SemanticEpoch do
  @moduledoc """
  Epoch-aware semantic projection: reads smalt's real manufacturing state and
  projects it as an epoch timeline — what was manufactured, when, from which
  pack digest, and with what drift status.

  Sources (all real files on disk, never in-memory shadows):

    * receipts under `.ggen_igniter/receipts/*.jsonl` — one admitted
      manufacture act per line, carrying `pack_name`, `pack_digest`,
      `standing`, `recipe_key`.
    * `ggen_igniter.pack.lock` — the admitted pack digests (the lock is the
      authority for what "drift" means: a receipt whose `pack_digest` differs
      from the locked digest for the same pack is `:digest_drift`).
    * `tmp/ocel/deviations.jsonl` — admitted OCEL conformance deviations,
      read through the real `Smalt.Ocel.DeviationAdmission.read_all/1`.

  Concepts follow the semantic-manufacture-epoch pack
  (`sm:Epoch`, `sm:graphDigest` vs `sm:projectionDigest` identity-vs-truth)
  and ggen_igniter's `GgenIgniter.EpochWatermark`: identity is evidence, the
  timeline is a projection of receipts, never ambient authority.

  Exposed for docs and tests only — no router surface.

  ## Degradation policy (typed analysis, lens-7 — PINNED, not accidental)

  The surface carries two DELIBERATELY DIFFERENT degradation policies, split
  by input kind, not by file:

    * **Reference/authority input** (`ggen_igniter.pack.lock`) — the lock is
      a truth *baseline*, not evidence. Its absence is a normal first-run
      state (no lock yet -> `%{}` -> every stamped pack projects `:no_pack`).
      A malformed lock carries no baseline either, so it folds to `%{}` on
      the SAME lenient policy: the timeline is never killed by a missing
      baseline, and the degradation is VISIBLE (every pack `:no_pack`).
      Refusing the timeline would invert the lock's role — a broken ruler
      would stop all measurement.

    * **Evidence ledgers** (receipts `*.jsonl`, deviations) — each line is
      an admitted manufacture act or an observed conformance deviation.
      Degradation here would FABRICATE history (a silently skipped line is
      a dropped epoch) or destroy it (a crash hides every admitted act).
      Evidence conserves: a malformed line refuses the timeline typed
      (`{:malformed_receipt, path, line, _}` / `{:malformed_deviation, ...}`)
      with file+line location.

  The split is principled: **baselines degrade leniently with a visible
  drift marker; evidence refuses typed.** Do not unify them — a fold-to-%{}
  on a receipt ledger would drop admitted acts; a typed refusal on the lock
  would let one corrupt file deny the whole timeline. Any new input to this
  surface must declare which kind it is and take the matching policy.
  """

  alias Smalt.Ocel.DeviationAdmission
  alias Smalt.Projection.Identity

  @default_receipts_dir Path.join([".ggen_igniter", "receipts"])
  @default_pack_lock "ggen_igniter.pack.lock"
  @default_deviations_path Path.join(["tmp", "ocel", "deviations.jsonl"])

  @type drift_status :: :ok | :digest_drift | :standing_drift | :no_pack

  @type epoch_row :: %{
          required(:id) => String.t(),
          required(:started_at) => DateTime.t() | nil,
          required(:finished_at) => DateTime.t() | nil,
          required(:standing) => String.t() | nil,
          required(:operation) => String.t() | nil,
          required(:pack_name) => String.t() | nil,
          required(:pack_digest) => String.t() | nil,
          required(:lock_digest) => String.t() | nil,
          required(:drift_status) => drift_status(),
          required(:drift) => boolean(),
          required(:recipe_key) => String.t() | nil,
          required(:receipt_hash) => String.t() | nil
        }

  @type timeline :: %{
          required(:epochs) => [epoch_row(), ...],
          required(:pack_lock) => %{String.t() => String.t()},
          required(:deviations) => [map()],
          required(:deviation_count) => non_neg_integer()
        }

  @doc """
  Projects the full epoch timeline from real files on disk.

  Options:

    * `:receipts_dir` — directory of `*.jsonl` receipt ledgers.
    * `:pack_lock` — path to the ggen_igniter pack lock file.
    * `:deviations_path` — path to the OCEL deviation ledger.

  Returns `{:ok, timeline}`; timeline is sorted ascending by
  `{started_at, id}` — a total, deterministic order, so repeated calls over
  an unchanged tree return byte-identical timelines.
  """
  @spec timeline(keyword()) :: {:ok, timeline()} | {:error, term()}
  def timeline(opts \\ []) do
    receipts_dir = Keyword.get(opts, :receipts_dir, @default_receipts_dir)
    pack_lock_path = Keyword.get(opts, :pack_lock, @default_pack_lock)
    deviations_path = Keyword.get(opts, :deviations_path, @default_deviations_path)

    lock = read_pack_lock(pack_lock_path)

    with {:ok, deviations} <- read_deviations(deviations_path),
         {:ok, receipts} <- read_receipts(receipts_dir),
         {:ok, receipts} <- refuse_duplicate_ids(receipts) do
      epochs =
        receipts
        |> Enum.map(&to_epoch_row(&1, lock))
        |> Enum.map(&ensure_datetime/1)
        |> Enum.sort(fn a, b ->
          case DateTime.compare(a.started_at, b.started_at) do
            :eq -> a.id <= b.id
            :lt -> true
            :gt -> false
          end
        end)

      {:ok,
       %{
         epochs: epochs,
         pack_lock: lock,
         deviations: deviations,
         deviation_count: length(deviations)
       }}
    end
  end

  ## Internals

  # Typed refusal (cycle-3): DeviationAdmission.read_all/1 decodes with
  # Jason.decode!/1 and raises on a malformed deviations ledger. The epoch
  # projection adapts that boundary raise into a typed refusal instead of a
  # crash.
  defp read_deviations(path) do
    DeviationAdmission.read_all(path)
  rescue
    e in Jason.DecodeError -> {:error, {:malformed_deviation, path, e}}
  end

  # Typed refusal (cycle-3 fuzz): a malformed JSONL line (including a
  # truncated last line) refuses the timeline with file+line location —
  # never a crash, never a silently-skipped receipt.
  @spec read_receipts(String.t()) ::
          {:ok, [map()]} | {:error, {:malformed_receipt, term()} | {:receipt_unreadable, term()}}
  defp read_receipts(dir) do
    # Lens-6 cycle 4: a missing/unreadable receipts DIR fell through the
    # with as a BARE {:error, :enoent} — an unlocated refusal (the
    # located-refusal discipline this surface closed lens-5). Wrap it on
    # the same {:receipt_unreadable, path, reason} axis as the per-file
    # clause below, so every refusal names its subject.
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
          case File.read(path) do
            {:ok, body} ->
              decode_all(String.split(body, "\n", trim: true), path, 1, acc)

            {:error, reason} ->
              {:halt, {:error, {:receipt_unreadable, path, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:receipt_unreadable, dir, reason}}
    end
  end

  defp decode_all([], _path, _line_no, acc), do: {:cont, {:ok, acc}}

  defp decode_all([line | rest], path, line_no, acc) do
    case Jason.decode(line) do
      # Lens-5 cycle 4: a valid-JSON NON-MAP line (array/string/number) is a
      # malformed receipt — previously it decoded fine and crashed the WHOLE
      # timeline out of Access (`receipt["id"]` on a list: "the Access module
      # supports only keyword lists"). Refuse typed with line location, same
      # malformed_receipt axis, never a crash.
      {:ok, receipt} when is_map(receipt) ->
        decode_all(rest, path, line_no + 1, [receipt | acc])

      {:ok, non_map} ->
        {:halt, {:error, {:malformed_receipt, path, line_no, {:non_map_line, non_map}}}}

      {:error, %Jason.DecodeError{} = err} ->
        {:halt, {:error, {:malformed_receipt, path, line_no, err}}}
    end
  end

  # Typed refusal (lens-2 cycle 2): a receipt without a binary id has no
  # identity — R_missing_identity — and two such receipts would previously
  # BOTH project (dup check filtered to binaries first), silently admitting
  # the same manufacture act twice. Refuse instead: every projected epoch
  # carries an identity.
  #
  # Lens-3 cycle 1: the empty string IS a binary — it passed the binary
  # fence and projected with id "". A blank binary carries zero identity
  # bits; refuse it on the same R_missing_identity axis.
  #
  # Lens-4 cycle 1: identity?/1 generalizes to Smalt.Projection.Identity —
  # whitespace-only ("  \t") and invisible-format-only ("\\u200B") ids also
  # carry zero VISIBLE identity bits and previously projected as-is.
  defp refuse_duplicate_ids(receipts) do
    ids = Enum.map(receipts, & &1["id"])

    ids = Enum.with_index(ids)

    case Enum.find(ids, fn {id, _} -> not Identity.valid?(id) end) do
      nil ->
        dup = find_dup(Enum.map(ids, fn {id, _} -> id end))

        if dup, do: {:error, {:duplicate_receipt_id, dup}}, else: {:ok, receipts}

      {bad, _i} ->
        {:error, {:receipt_missing_id, bad}}
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

  defp to_epoch_row(receipt, lock) do
    started_at = parse_ts(receipt["started_at"])
    finished_at = parse_ts(receipt["finished_at"])
    pack_name = receipt["pack_name"]
    pack_digest = receipt["pack_digest"]
    standing = receipt["standing"]

    {drift_status, lock_digest} = drift(pack_name, pack_digest, standing, lock)

    %{
      id: receipt["id"],
      started_at: started_at,
      finished_at: finished_at,
      standing: standing,
      operation: receipt["operation"],
      pack_name: nil_from_blank(pack_name),
      pack_digest: nil_from_blank(pack_digest),
      lock_digest: lock_digest,
      drift_status: drift_status,
      drift: drift_status != :ok,
      recipe_key: receipt["recipe_key"],
      receipt_hash: receipt["receipt_hash"]
    }
  end

  defp drift(pack_name, pack_digest, standing, lock) do
    lock_digest = if is_binary(pack_name), do: Map.get(lock, pack_name)

    cond do
      is_binary(standing) and standing != "alive" ->
        {:standing_drift, lock_digest}

      # Fence (cycle-2 mutation court): a pack_name the lock does not admit
      # is a forged/foreign stamp — drift, never a silent pass.
      is_nil(pack_name) ->
        {:no_pack, nil}

      is_nil(lock_digest) ->
        {:no_pack, nil}

      lock_digest != pack_digest ->
        {:digest_drift, lock_digest}

      true ->
        {:ok, lock_digest}
    end
  end

  defp nil_from_blank(nil), do: nil
  defp nil_from_blank(""), do: nil
  defp nil_from_blank(other), do: other

  # Lens-3 cycle 6: boundary crash class — a non-binary timestamp (tampered
  # receipt with an integer epoch, list, etc.) raised FunctionClauseError
  # out of DateTime.from_iso8601/1 and crashed the WHOLE timeline. The
  # malformed-value policy here is the existing lenient one (unparseable →
  # nil → epoch-0 sort bucket), extended to non-binaries.
  defp parse_ts(nil), do: nil
  defp parse_ts(ts) when not is_binary(ts), do: nil
  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp ensure_datetime(%{started_at: nil} = row), do: %{row | started_at: ~U[1970-01-01T00:00:00Z]}
  defp ensure_datetime(row), do: row

  defp read_pack_lock(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"packs" => packs}} when is_map(packs) ->
            # Lens-6 cycle 1: a structurally valid top level with a
            # malformed PACK ENTRY (non-map value "just-a-string", list
            # packs, entry missing "sha256" or carrying a non-binary
            # digest) previously crashed the WHOLE timeline out of the
            # Map.new payload pattern (FunctionClauseError, witnessed:
            # tmp/f16L6/probe1.out probes A+B). Same lenient policy as a
            # missing lock: the whole lock folds to %{} — every pack then
            # projects :no_pack drift, so the degradation is VISIBLE in
            # the timeline, never a silent pass.
            packs
            |> Enum.reduce_while(%{}, fn
              {name, %{"sha256" => digest}}, acc when is_binary(digest) ->
                # Lens-7 cycle 2 (mutation court): the former is_binary(name)
                # conjunct was a VACUITY — Jason object keys are always
                # binaries, so no input through timeline/1 can falsify it
                # (mutant lock-nonameguard: 20 tests, 0 failure). Removed.
                {:cont, Map.put(acc, name, digest)}

              _malformed, _acc ->
                {:halt, :malformed_lock}
            end)
            |> case do
              :malformed_lock -> %{}
              lock when is_map(lock) -> lock
            end

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
