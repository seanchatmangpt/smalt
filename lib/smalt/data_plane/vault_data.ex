defmodule Smalt.DataPlane.VaultData do
  @moduledoc """
  Data-plane sweep helper for the vault secrets store (`:smalt_vault_secrets`,
  the 8443 `/secrets` surface owned by `Smalt.EgressRouter`).

  Mirrors the `BlobStorage.drop_account_data/1` capture-then-sweep pattern
  (D127) for the vault branch of the FR-6 composite-fixture teardown: when a
  vault (or its enclosing resource group) is deleted on the ARM plane, its
  seeded data-plane secret rows must not orphan and stay GETable on 8443.

  Keys in `:smalt_vault_secrets` are BARE secret names (`seed_data_plane_secret/5`
  does `Store.put(:smalt_vault_secrets, name, record)`) — there is no vault
  scoping in the key, so the sweep needs the secret names captured from the
  swept ARM child records before deletion.
  """

  alias Smalt.Store

  @doc """
  Deletes the data-plane secret rows for the given bare secret names.
  Tolerates a missing table (pre-Store boot) — mirrors the
  `:ets.info/1 != :undefined` fence used by EgressRouter's secret handlers.
  """
  @spec drop_vault_secrets([binary()]) :: :ok
  def drop_vault_secrets(names) when is_list(names) do
    if :ets.info(:smalt_vault_secrets) != :undefined do
      for name <- names, do: Store.delete(:smalt_vault_secrets, name)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Secret backup/restore (KD-103) — Azure Key Vault shape:
  #   POST /secrets/{name}/backup -> 200 {"value": "<base64 blob>"}
  #   POST /secrets/{name}/restore (body {"value": blob}) -> 200/201
  # The blob is base64 of a JSON envelope carrying the secret bundle
  # (name/value/contentType/attributes + version history) plus an inner
  # SHA-256 checksum over the bundle; restore verifies the checksum and
  # refuses tampered blobs with a typed MalformedBackupBlob-class 400.
  # ---------------------------------------------------------------------------

  @typedoc "Typed restore refusal: {:error, code, message}"
  @type restore_error :: {:error, binary(), binary()}

  @doc """
  Backs up the live secret `name` as an opaque `{"value" => blob}` map
  (Azure backup shape). Returns `:error` when the secret does not exist
  or the store table is not booted — callers map that to 404 SecretNotFound.
  """
  @spec backup_secret(binary()) :: {:ok, %{binary() => binary()}} | :error
  def backup_secret(name) when is_binary(name) do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      :error
    else
      case Store.get(:smalt_vault_secrets, name) do
        {:ok, record} -> {:ok, %{"value" => encode_backup(name, record)}}
        :error -> :error
      end
    end
  end

  @doc """
  Restores a backup blob (the `value` of the backup envelope) under its
  encapsulated secret name. Returns `{:ok, :created}` when the name was not
  live (fresh restore), `{:ok, :conflict}` when a live secret already exists
  under that name (Azure 409), or `{:error, code, message}` for malformed or
  checksum-failing blobs (`MalformedBackupBlob`-class typed face).
  """
  @spec restore_secret(binary(), binary()) ::
          {:ok, :created | :conflict} | restore_error()
  def restore_secret(blob, host) when is_binary(blob) and is_binary(host) do
    with :ok <- table_ready(),
         {:ok, name, bundle} <- decode_backup(blob),
         {:ok, record} <- bundle_to_record(bundle, host),
         conflict <-
           (case Store.get(:smalt_vault_secrets, name) do
              {:ok, _} -> :conflict
              :error -> :created
            end),
         :ok <- if(conflict == :conflict, do: {:error, "Conflict", conflict_message(name)}, else: :ok) do
      Store.put(:smalt_vault_secrets, name, record)
      {:ok, conflict}
    else
      {:error, _code, _msg} = refusal -> refusal
    end
  end

  defp table_ready do
    if :ets.info(:smalt_vault_secrets) == :undefined,
      do: {:error, "VaultNotReady", "secret store is not booted"},
      else: :ok
  end

  defp encode_backup(name, record) do
    bundle = %{
      "name" => name,
      "value" => record["value"],
      "contentType" => record["attributes"]["contentType"],
      "attributes" => Map.take(record["attributes"] || %{}, ["enabled", "created", "updated", "exp", "expires"]),
      "version_history" => [%{"version" => record["version"], "created" => record["attributes"]["created"]}]
    }

    envelope = %{"checksum" => bundle_checksum(bundle), "bundle" => bundle}
    envelope |> Jason.encode!() |> Base.encode64()
  end

  defp decode_backup(b64) do
    with true <- is_binary(b64),
         {:ok, json} <- decode64_json(b64),
         %{"checksum" => checksum, "bundle" => bundle} when is_map(bundle) and is_binary(checksum) <- json,
         ^checksum <- bundle_checksum(bundle) do
      {:ok, bundle["name"], bundle}
    else
      %{} = partial when is_map(partial) ->
        {:error, "MalformedBackupBlob", "backup blob is missing checksum or bundle fields"}

      {:error, _reason} ->
        {:error, "MalformedBackupBlob", "backup blob is not base64-encoded JSON"}

      _checksum_mismatch ->
        {:error, "MalformedBackupBlob", "backup blob checksum mismatch (tampered or truncated)"}
    end
  end

  defp decode64_json(b64) do
    case Base.decode64(b64) do
      {:ok, json} -> Smalt.JsonCompat.decode(json)
      :error -> {:error, "not base64"}
    end
  end

  defp bundle_checksum(bundle) do
    :crypto.hash(:sha256, Jason.encode!(bundle))
    |> Base.encode16(case: :lower)
  end

  defp bundle_to_record(bundle, host) do
    with name when is_binary(name) and name != "" <- bundle["name"],
         value when is_binary(value) <- bundle["value"] do
      version = Integer.to_string(System.unique_integer([:positive]))
      created = bundle |> attrs() |> Map.get("created") || System.system_time(:second)

      attributes =
        bundle |> attrs() |> Map.merge(%{"created" => created, "updated" => System.system_time(:second)})

      record = %{
        "value" => value,
        "id" => "https://#{host}:8443/secrets/#{name}/#{version}",
        "attributes" => attributes,
        "version" => version
      }

      {:ok, maybe_put_content_type(record, bundle)}
    else
      _ -> {:error, "MalformedBackupBlob", "backup bundle requires string \"name\" and \"value\""}
    end
  end

  defp attrs(bundle), do: bundle["attributes"] || %{}

  defp maybe_put_content_type(record, bundle) do
    case bundle["contentType"] do
      ct when is_binary(ct) -> put_in(record, ["attributes", "contentType"], ct)
      _ -> record
    end
  end

  defp conflict_message(name),
    do: "secret #{name} already exists and is live; delete (or purge) it before restore"

  @doc """
  Capture-then-sweep: extracts bare secret names from swept ARM store keys.
  """
  def vault_secret_names(keys) do
    keys
    |> List.wrap()
    |> Enum.flat_map(fn key ->
      case Regex.run(~r/vaults\/[^\/]+\/secrets\/([^\/]+)/i, key, capture: :all_but_first) do
        [name] -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end
end
