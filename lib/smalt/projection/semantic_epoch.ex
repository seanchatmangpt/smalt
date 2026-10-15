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
  """

  alias Smalt.Ocel.DeviationAdmission

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
    {:ok, deviations} = DeviationAdmission.read_all(deviations_path)

    epochs =
      receipts_dir
      |> list_receipt_files()
      |> Enum.flat_map(&read_receipts/1)
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

  ## Internals

  defp list_receipt_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp read_receipts(path) do
    path
    |> File.read()
    |> case do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
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

      is_nil(pack_name) ->
        {:no_pack, nil}

      is_binary(lock_digest) and lock_digest != pack_digest ->
        {:digest_drift, lock_digest}

      true ->
        {:ok, lock_digest}
    end
  end

  defp nil_from_blank(nil), do: nil
  defp nil_from_blank(""), do: nil
  defp nil_from_blank(other), do: other

  defp parse_ts(nil), do: nil

  defp parse_ts(ts) do
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
          {:ok, %{"packs" => packs}} ->
            Map.new(packs, fn {name, %{"sha256" => digest}} -> {name, digest} end)

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
