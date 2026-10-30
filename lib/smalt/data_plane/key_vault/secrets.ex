defmodule Smalt.DataPlane.KeyVault.Secrets do
  @moduledoc """
  Key Vault secrets face: PATCH attributes/tags, soft delete / get / list /
  recover / purge over the `:smalt_vault_secrets` Store table.

  The deleted-bundle shadow table (`:smalt_vault_deleted_keys`, tuple-keyed
  `{:secret, name}`) is owned by `Smalt.DataPlane.KeyVault.Keys` (one
  registry individual, both planes); this face consumes its `@doc false`
  seams (`deleted_table/0`, `ensure_deleted_table/0`, `purge_protection?/1`,
  `real_purge_date/1`) rather than re-aliasing the table.
  """

  alias Smalt.DataPlane.KeyVault.Keys
  alias Smalt.Store

  # w6bn: secrets twin of update_key_properties — attributes-only update
  # (enabled/exp/nbf) + tags merge, material untouched, `updated` re-stamped.
  # The secrets store is keyed by bare name (one row per name, the row's
  # "id" carries the version); a version argument must MATCH the stored
  # version (a stale version is a 404, not a silent latest-hit).
  @doc """
  Updates secret attributes / tags on an existing secret (PATCH /secrets/:name
  or /secrets/:name/:version). Attributes merge (enabled/exp/nbf), tags merge;
  the secret's value never rotates. Version omitted -> latest; a version that
  does not match the stored row is a 404 SecretNotFound.
  Returns `{:ok, 200, public_record}` or `{:error, 404, not_found}`.
  """
  def update_secret_properties(name, params, version \\ nil) do
    # KD-COVERS: KD-184 — a version segment resolves the RETAINED version row
    # (any version in history), not just the latest; unknown version stays a
    # typed 404 SecretNotFound.
    version_row? =
      version not in [nil, ""] and
        match?({:ok, _}, Store.get(:smalt_vault_secrets, {name, version}))

    cond do
      version_row? ->
        {:ok, record} = Store.get(:smalt_vault_secrets, {name, version})
        patch_secret_record(name, record, params, store_key: {name, version})

      true ->
        case Store.get(:smalt_vault_secrets, name) do
          {:ok, record} ->
            stored_version = Map.get(record, "version")

            if version in [nil, ""] or version == stored_version do
              patch_secret_record(name, record, params, store_key: name)
            else
              {:error, 404, secret_not_found()}
            end

          :error ->
            {:error, 404, secret_not_found()}
        end
    end
  end

  defp patch_secret_record(name, record, params, store_key: store_key) do
    attrs = Map.get(record, "attributes", %{})

    new_attrs =
      Map.get(params, "attributes") || Map.get(params, "secretAttributes") || %{}

    merged_attrs =
      attrs
      |> Map.merge(new_attrs)
      |> Map.put("updated", System.system_time(:second))

    tags = Map.get(record, "tags", %{})
    new_tags = Map.get(params, "tags") || %{}
    merged_tags = Map.merge(tags, new_tags)

    updated_record =
      record
      |> Map.put("attributes", merged_attrs)
      |> Map.put("tags", merged_tags)

    Store.put(:smalt_vault_secrets, store_key, updated_record)

    # Bare-name (latest) patch mirrors onto the latest version's retained row
    # so the version-addressed read never drifts from the latest view.
    case store_key do
      ^name ->
        case updated_record["version"] do
          v when is_binary(v) ->
            case Store.get(:smalt_vault_secrets, {name, v}) do
              {:ok, _row} ->
                Store.put(
                  :smalt_vault_secrets,
                  {name, v},
                  Map.put(updated_record, "is_version_row", true)
                )

              :error ->
                :ok
            end

          _ ->
            :ok
        end

      _version_row ->
        :ok
    end

    {:ok, 200, public_secret_record(updated_record)}
  end

  # KD-03 split-brain fix (v26.10.31): this engine face serves the 8443
  # point PATCH (update_secret_properties) — a POINT operation, so the value
  # ECHOES, matching the router's point face (AppConfigRoutes.public_secret_record/1
  # keeps "value") and real Azure's SecretBundle-on-update contract. Per-face
  # value-echo polarity law (posh KD-03):
  #   8443 point GET/PATCH  -> value ECHOES   (this face, drop-list below)
  #   8443 list faces       -> value NEVER    (list_secret_record/1, KvRoutes)
  #   engine soft-delete    -> value NEVER    (public_deleted_secret/1 below)
  #   ARM face              -> value echoes VERBATIM (posh KD-03 law)
  # Internal bookkeeping (version/versions/created_seq/is_version_row) never
  # leaves the vault on any face.
  defp public_secret_record(record) do
    Map.drop(record, ["version", "versions", "created_seq", "is_version_row"])
  end

  defp secret_not_found do
    %{
      "error" => %{
        "code" => "SecretNotFound",
        "message" => "A secret with (name/id) was not found in this key vault."
      }
    }
  end

  defp not_found(code), do: %{"error" => %{"code" => code}}

  defp public_deleted_secret(deleted) do
    # KD-S3 bookkeeping (versions index, captured version rows) never leaves
    # the vault on the deleted-secret bundle, and neither does the value —
    # engine soft-delete NEVER echoes (posh KD-03 polarity law, v26.10.31;
    # the value stays in the store row for recover to restore).
    Map.drop(deleted, ["value", "is_deleted_secret", "versions", "version_rows", "created_seq"])
  end

  # ---------------------------------------------------------------------------
  # Soft delete / recover / purge (secrets) — KD-102
  # ---------------------------------------------------------------------------
  #
  # Deleted secrets share the `Keys.deleted_table()` with deleted keys, namespaced by
  # tuple keys `{:secret, name}` (binary keys remain deleted KEYS). The table is
  # a registry-declared shadow table owned by this module; reusing it avoids a
  # second registry individual for a sim-state surface. All list/read paths
  # filter on the tuple shape so the two planes never see each other's rows.

  @doc """
  `DELETE /secrets/:name` (soft delete, real Azure contract). Removes the
  secret from the live surface (subsequent `GET /secrets/:name` 404s
  SecretNotFound) and moves it to the deleted-bundle table with `recoveryId`,
  `deletedDate` and `scheduledPurgeDate` (epoch seconds, 90-day retention).
  Returns the deleted-secret bundle (real wire shape includes the value).
  """
  def delete_secret(name) do
    Keys.ensure_deleted_table()

    case Store.get(:smalt_vault_secrets, name) do
      {:ok, record} ->
        now = System.system_time(:second)

        # KD-COVERS: KD-185 — retained version history rides the soft delete.
        # Version rows ({name, version}) are captured into the deleted bundle
        # ("version_rows", mirrors the deleted-keys contract) so a recover
        # restores the exact material each version had; purge drops them. The
        # "versions" index stays on the record so the recovered row keeps its
        # history ordering.
        versions = record |> Map.get("versions", []) |> List.wrap()

        version_rows =
          Map.new(versions, fn v ->
            case Store.get(:smalt_vault_secrets, {name, v}) do
              {:ok, row} -> {v, row}
              :error -> {v, record}
            end
          end)

        deleted =
          record
          |> Map.put("deletedDate", now)
          |> Map.put("scheduledPurgeDate", Keys.real_purge_date(now))
          |> Map.put("recoveryId", "https://smalt-vault/deletedsecrets/#{name}")
          |> Map.put("is_deleted_secret", true)
          |> Map.put("version_rows", version_rows)

        Enum.each(version_rows, fn {v, _row} ->
          Store.delete(:smalt_vault_secrets, {name, v})
        end)

        Store.delete(:smalt_vault_secrets, name)
        Store.put(Keys.deleted_table(), {:secret, name}, deleted)

        {:ok, 200, public_deleted_secret(deleted)}

      :error ->
        {:error, 404, not_found("SecretNotFound")}
    end
  end

  @doc """
  `GET /deletedsecrets/:name`. The deleted-secret bundle (`recoveryId`,
  `deletedDate`, `scheduledPurgeDate`). Unknown or purged secret -> 404
  SecretNotFound. The live path (`GET /secrets/:name`) 404s by construction —
  the live row is gone.
  """
  def get_deleted_secret(name) do
    Keys.ensure_deleted_table()

    case Store.get(Keys.deleted_table(), {:secret, name}) do
      {:ok, deleted} -> {:ok, 200, public_deleted_secret(deleted)}
      :error -> {:error, 404, not_found("SecretNotFound")}
    end
  end

  @doc """
  `GET /deletedsecrets`. All deleted-secret bundles, key order.
  """
  def list_deleted_secrets do
    Keys.ensure_deleted_table()

    {:ok, 200,
     %{
       "value" =>
         # list_all/1, not list/1: list/1 filters to the binary-key prefix
         # contract and silently drops tuple-keyed rows — deleted secrets ride
         # {:secret, name} tuple keys, so list/1 would return an empty listing
         # forever (witnessed live 2026-10-20: deleted secret present, list []).
         Enum.flat_map(Store.list_all(Keys.deleted_table()), fn
           %{"is_deleted_secret" => true} = record -> [public_deleted_secret(record)]
           _ -> []
         end)
     }}
  end

  @doc """
  `POST /deletedsecrets/:name/recover`. Restores the soft-deleted secret to the
  live surface; the deleted entry is removed. Unknown or purged secret -> 404
  SecretNotFound.
  """
  def recover_deleted_secret(name) do
    Keys.ensure_deleted_table()

    case Store.get(Keys.deleted_table(), {:secret, name}) do
      {:ok, deleted} ->
        {version_rows, deleted} = Map.pop(deleted, "version_rows", %{})

        restored =
          deleted
          |> Map.drop(["deletedDate", "scheduledPurgeDate", "recoveryId", "is_deleted_secret"])

        Store.put(:smalt_vault_secrets, name, restored)

        # KD-COVERS: KD-185 — recover re-puts the captured version rows so the
        # retained history stays addressable after recovery.
        Enum.each(version_rows || %{}, fn {v, row} ->
          Store.put(:smalt_vault_secrets, {name, v}, Map.put(row, "is_version_row", true))
        end)

        Store.delete(Keys.deleted_table(), {:secret, name})
        {:ok, 200, restored}

      :error ->
        {:error, 404, not_found("SecretNotFound")}
    end
  end

  @doc """
  `POST /deletedsecrets/:name/purge`. Permanent removal — recover then 404s.
  A secret flagged with purge protection (`"purge_protection": true` or
  `attributes.purgeProtection`) refuses with `409 Conflict`, mirroring the
  deleted-keys contract.
  """
  def purge_deleted_secret(name) do
    Keys.ensure_deleted_table()

    case Store.get(Keys.deleted_table(), {:secret, name}) do
      {:ok, deleted} ->
        if Keys.purge_protection?(deleted) do
          {:error, 409,
           %{
             "error" => %{
               "code" => "Conflict",
               "message" =>
                 "#{name} is protected against purge by a vault-level purge protection policy."
             }
           }}
        else
          # KD-COVERS: KD-185 — purge drops the retained version rows for good.
          Enum.each(Map.get(deleted, "version_rows", %{}) || %{}, fn {v, _row} ->
            Store.delete(:smalt_vault_secrets, {name, v})
          end)

          Store.delete(Keys.deleted_table(), {:secret, name})
          {:ok, 204, %{}}
        end

      :error ->
        {:error, 404, not_found("SecretNotFound")}
    end
  end
end
