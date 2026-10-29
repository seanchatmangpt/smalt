defmodule Smalt.DataPlane.BlobSoftDelete do
  @moduledoc """
  Blob soft-delete + versioning faces (wave-6 lane w6aw), engine-side module.

  Real Azure parity: service-properties `<DeleteRetentionPolicy>` enables
  soft-delete (Delete Blob parks the blob instead of hard delete; List Blobs
  `include=deleted` shows `<Deleted>true</Deleted>`; Undelete Blob restores).
  `<IsVersioningEnabled>` freezes each overwrite's prior record as an
  immutable version retrievable by `include=versions` or by version-id.
  `soft_delete_sweep/1` is count-only (the analytical-view projection law).

  Storage: dedicated ETS tables, heir'd per the shadow-table law
  (`{:heir, Process.whereis(:init), []}` 3-tuple).
  """

  alias Smalt.DataPlane.BlobStorage, as: BS

  @deleted_table :smalt_blob_soft_deleted
  @versions_table :smalt_blob_versions
  @props_table :smalt_blob_soft_delete_props

  # ---------------------------------------------------------------------------
  # Tables
  # ---------------------------------------------------------------------------

  @doc false
  def ensure_tables do
    ensure_table(@deleted_table)
    ensure_table(@versions_table)
  end

  # Race-safe idempotent creation: concurrent callers (32-parallel PUT court)
  # can pass the :ets.info check together; the loser of the :ets.new race
  # raises ArgumentError ("table name already exists") and treats the winner's
  # table as the outcome. Never a crash on the request path.
  defp ensure_table(name) do
    if :ets.info(name) == :undefined do
      try do
        :ets.new(name, [
          :set,
          :named_table,
          :public,
          {:heir, Process.whereis(:init), []},
          read_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Delete retention policy (service-properties extension)
  # ---------------------------------------------------------------------------

  @doc """
  Parse + store the `<DeleteRetentionPolicy>` block from a Put Blob Service
  Properties body. `{:ok, policy}` or
  `{:error, 400, "InvalidXmlDocument" | "InvalidHeaderValue", msg}`.

  Three-case parse (EXPL-3-T1 repair, real Azure contract):

  - empty body = the legal "clear" operation → 200, policy disabled;
  - envelope-parseable body = parse + apply (Enabled/Days rules below);
  - non-empty body WITHOUT the expected envelope = typed 400
    InvalidXmlDocument, and the prior stored policy is left UNCHANGED
    (never a silent disable).
  Enabled requires Days in 1..365 (real Azure range).
  """
  def set_delete_retention_policy(account, xml_body) when is_binary(xml_body) do
    ensure_tables()
    ensure_props_table()

    case Regex.run(~r/<DeleteRetentionPolicy>(.*?)<\/DeleteRetentionPolicy>/s, xml_body) do
      [_, block] ->
        enabled? = xml_text(block, "Enabled") in ["true", "1"]
        days = parse_days(xml_text(block, "Days"))

        cond do
          enabled? and days == nil ->
            {:error, 400, "InvalidHeaderValue",
             "DeleteRetentionPolicy Enabled=true requires Days between 1 and 365."}

          enabled? and (days < 1 or days > 365) ->
            {:error, 400, "InvalidHeaderValue",
             "DeleteRetentionPolicy Days must be between 1 and 365."}

          true ->
            policy =
              if enabled? do
                %{"enabled" => true, "days" => days}
              else
                %{"enabled" => false}
              end

            :ets.insert(@props_table, {{:delete_retention, account}, policy})
            {:ok, policy}
        end

      # Empty body: the legal clear — store disabled, 200.
      _ when xml_body == "" ->
        :ets.insert(@props_table, {{:delete_retention, account}, %{"enabled" => false}})
        {:ok, %{"enabled" => false}}

      # Non-empty but no envelope: real Azure answers 400 InvalidXmlDocument;
      # never silently disable (and never touch) the prior policy.
      _ ->
        {:error, 400, "InvalidXmlDocument",
         "Missing required XML element 'DeleteRetentionPolicy'."}
    end
  end

  @doc "Stored delete-retention policy for `account` (nil when never set)."
  def delete_retention_policy(account) do
    ensure_tables()
    ensure_props_table()

    case :ets.lookup(@props_table, {:delete_retention, account}) do
      [{{:delete_retention, ^account}, policy}] -> policy
      [] -> nil
    end
  end

  @doc """
  Parse + store `<IsVersioningEnabled>` from a Put Blob Service Properties
  body. `{:ok, boolean}` or `{:error, 400, "InvalidXmlDocument", msg}`.

  Same three-case parse as `set_delete_retention_policy/2` (EXPL-3-T1): empty
  body = legal clear (versioning off, 200); envelope-parseable = parse + apply;
  non-empty non-envelope = typed 400 InvalidXmlDocument with the prior
  versioning flag left UNCHANGED.
  """
  def set_versioning_enabled(account, xml_body) when is_binary(xml_body) do
    ensure_tables()
    ensure_props_table()

    case Regex.run(~r/<IsVersioningEnabled>(.*?)<\/IsVersioningEnabled>/s, xml_body) do
      [_, v] ->
        enabled? = String.trim(v) in ["true", "1"]
        :ets.insert(@props_table, {{:versioning, account}, enabled?})
        {:ok, enabled?}

      # Empty body: the legal clear.
      _ when xml_body == "" ->
        :ets.insert(@props_table, {{:versioning, account}, false})
        {:ok, false}

      # Non-empty but no envelope: typed 400, prior flag untouched.
      _ ->
        {:error, 400, "InvalidXmlDocument", "Missing required XML element 'IsVersioningEnabled'."}
    end
  end

  @doc "Versioning enabled? for `account` (false when unset)."
  def versioning_enabled?(account) do
    ensure_tables()
    ensure_props_table()

    case :ets.lookup(@props_table, {:versioning, account}) do
      [{{:versioning, ^account}, flag}] -> flag
      [] -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete / undelete
  # ---------------------------------------------------------------------------

  @doc """
  Delete-Blob interception (called by the blob delegator BEFORE
  `BlobStorage.delete_blob/6`): when a delete-retention policy is enabled for
  `account`, park the blob record in `@deleted_table` (with deletion_time,
  remaining_retention_days) and return `{:soft, result}` telling the caller
  the delete already produced the 202; `:pass` when no policy (normal hard
  delete).
  """
  def intercept_delete(account, container, blob_name, _opts \\ []) do
    ensure_tables()

    case delete_retention_policy(account) do
      %{"enabled" => true} = policy ->
        blob_key = "#{account}/#{container}/#{blob_name}"

        case BS.get_blob(account, container, blob_name) do
          {:ok, blob} ->
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            frozen = blob |> Map.put("deleted", true) |> Map.put("deletion_time", now)

            frozen =
              Map.put(frozen, "remaining_retention_days", policy["days"])

            :ets.insert(@deleted_table, {blob_key, frozen})
            # Real soft-delete parity: the parked row leaves normal enumeration
            # (List Blobs / Get answer 404) — remove the live row too.
            Smalt.Store.delete(:smalt_blobs, blob_key)
            {:soft, {:ok, 202, %{"x-ms-request-id" => "w6aw"}, nil}}

          err404 ->
            {:soft, err404}
        end

      _ ->
        :pass
    end
  end

  @doc """
  Undelete Blob (`PUT ?comp=undelete`): restores the most recent soft-deleted
  instance. `{:ok, 200, headers, nil}` or typed 404 `BlobNotFound`.
  """
  def undelete_blob(account, container, blob_name) do
    ensure_tables()
    blob_key = "#{account}/#{container}/#{blob_name}"

    case :ets.lookup(@deleted_table, blob_key) do
      [{^blob_key, frozen}] ->
        restored = Map.drop(frozen, ["deleted", "deletion_time", "remaining_retention_days"])

        BS.put_blob(
          account,
          container,
          blob_name,
          restored["content"],
          restored["headers"] || %{}
        )

        :ets.delete(@deleted_table, blob_key)
        {:ok, 200, %{"x-ms-request-id" => "w6aw", "x-ms-version" => "2021-12-02"}, nil}

      [] ->
        {:error, 404, "BlobNotFound", "No soft-deleted blob to restore."}
    end
  end

  @doc "Soft-deleted record for a blob or nil."
  def deleted_record(account, container, blob_name) do
    ensure_tables()

    case :ets.lookup(@deleted_table, blob_key(account, container, blob_name)) do
      [{_k, rec}] -> rec
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Versioning
  # ---------------------------------------------------------------------------

  @doc """
  Put-Blob interception (called by the blob delegator BEFORE put):
  when versioning is enabled and the blob already exists, freeze the prior
  record as a version (version_id = monotonic ms timestamp + counter).
  Returns :ok (proceed) — freezing failure never blocks the write.
  """
  def intercept_put(account, container, blob_name) do
    ensure_tables()

    if versioning_enabled?(account) do
      blob_key = blob_key(account, container, blob_name)

      case BS.get_blob(account, container, blob_name) do
        {:ok, prior} ->
          vid = version_id()
          :ets.insert(@versions_table, {{blob_key, vid}, Map.put(prior, "version_id", vid)})
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  List versions for a blob, newest first: `{:ok, [%{"version_id" => .., ..}]}`.
  Live/current row is not included (it is served by normal Get).
  """
  def list_versions(account, container, blob_name) do
    ensure_tables()
    bk = blob_key(account, container, blob_name)

    versions =
      @versions_table
      |> :ets.match_object({{bk, :_}, :_})
      |> Enum.map(fn {_k, rec} -> rec end)
      |> Enum.sort_by(fn r -> r["version_id"] end, :desc)

    {:ok, versions}
  end

  @doc "Fetch one prior version by version-id: {:ok, rec} or typed 404."
  def get_version(account, container, blob_name, version_id) do
    ensure_tables()
    bk = blob_key(account, container, blob_name)

    case :ets.lookup(@versions_table, {bk, version_id}) do
      [{{_bk, ^version_id}, rec}] -> {:ok, rec}
      [] -> {:error, 404, "BlobNotFound", "No such blob version."}
    end
  end

  # ---------------------------------------------------------------------------
  # Count-only sweep (analytical-view projection law)
  # ---------------------------------------------------------------------------

  @doc """
  Count-only retention sweep (never deletes): counts soft-deleted rows whose
  deletion_time is older than policy days for `account`. %{:expired => n, :kept => n}.
  """
  def soft_delete_sweep(account) do
    ensure_tables()

    {expired, kept} =
      @deleted_table
      |> :ets.tab2list()
      |> Enum.split_with(fn {_k, rec} -> expired?(rec, account) end)

    %{expired: length(expired), kept: length(kept)}
  end

  defp expired?(rec, account) do
    case {delete_retention_policy(account), rec["deletion_time"]} do
      {%{"enabled" => true, "days" => days}, t} when is_binary(t) and is_integer(days) ->
        ts = parse_iso_to_epoch(t)
        System.system_time(:second) - ts >= days * 86_400

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ensure_props_table do
    if :ets.info(@props_table) == :undefined do
      :ets.new(@props_table, [
        :set,
        :named_table,
        :public,
        {:heir, Process.whereis(:init), []},
        read_concurrency: true
      ])
    end

    :ok
  end

  defp xml_text(block, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, block) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp parse_days(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_days(_), do: nil

  defp blob_key(account, container, blob_name), do: "#{account}/#{container}/#{blob_name}"

  defp version_id, do: Integer.to_string(System.system_time(:millisecond))

  defp parse_iso_to_epoch(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        System.convert_time_unit(dt |> DateTime.to_unix(:millisecond), :millisecond, :second)

      _ ->
        0
    end
  end
end
