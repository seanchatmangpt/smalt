defmodule Smalt.DataPlane.KVManagedStorage do
  @moduledoc """
  Key Vault managed storage account keys (Azure 2016-10-01 KV data plane).

  Wave-6 lane w6b. Surface (all typed JSON faces):

    - `PUT /managedstorage/:name`           -> `create/3` (201 ManagedStorageAccount)
    - `GET /managedstorage`                 -> `list/0`
    - `GET /managedstorage/:name`           -> `get/1` (200 ManagedStorageAccount)
    - `DELETE /managedstorage/:name`        -> `delete/1` (200 deleted bundle)
    - `POST /managedstorage/:name/regeneratestorageaccountkey` -> `regenerate_key/3`
    - `GET /managedstorage/:name/keys`     -> `keys/1`
    - `PUT /managedstorage/:name/sas/:sasdef` -> `put_sas/4` (201 SasDefinition)
    - `GET /managedstorage/:name/sas`       -> `list_sas/1` (200 list)
    - `GET /managedstorage/:name/sas/:sasdef` -> `get_sas/2` (200 SasDefinition)
    - `DELETE /managedstorage/:name/sas/:sasdef` -> `delete_sas/2` (204)

  Managed storage account faces were retired in real Azure, but the wire face
  is part of the 2016-10-01 surface this plane emulates; parity here is the
  2016-10-01 contract, not the retirement state.

  ## Storage

  One module-owned, heir'd ETS table `:smalt_vault_managed_storage`
  (shadow-table law, same pattern as `Smalt.DataPlane.Certificates`):

    - binary key `name`        -> live account record
    - `{:sas, account, def}`   -> SAS definition record
    - `{:deleted, name}`       -> deleted bundle (soft delete)

  ## Typed errors

    - `409 ManagedStorageAccountNameAlreadyExists` (atomic insert_new)
    - `404 ManagedStorageAccountNotFound` / `ManagedStorageAccountDeleted`
    - `404 SasDefinitionNotFound`
    - `400 ManagedStorageInvalidBody` (bad active key name, non-boolean flags,
      non-binary resource id, malformed SAS template)
    - `400 ManagedStorageAccountNotRegenerated` (regenerate with
      autoRegenerateKey disabled)

  ## Table ownership

  `ensure_table/0` creates `:table` lazily with `heir: Process.whereis(:init)`
  (3-tuple form) so the table outlives the request task that first touched it.
  ArgumentError rescue keeps the multi-request create race fail-safe.
  Idempotent; safe from any process.
  """

  alias Smalt.Store

  @table :smalt_vault_managed_storage

  # ---------------------------------------------------------------------------
  # Table ownership (shadow-table law)
  # ---------------------------------------------------------------------------

  @doc """
  Ensures `#{@table}` exists, creating it lazily from whichever process first
  touches it with `heir: Process.whereis(:init)` (3-tuple form) so the table
  outlives its creator. Idempotent; safe from any process.
  """
  @spec ensure_table :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          {:heir, Process.whereis(:init), []},
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @doc """
  `PUT /managedstorage/:name`. Body (JSON object):

      {
        "activeKeyName": "key1" | "key2",
        "autoRegenerateKey": true | false,
        "storageAccountResourceId": "/subscriptions/.../storageAccounts/...",
        "storageAccountAttributes": {"enabled": true}    (optional)
      }

  `storageAccountResourceId` + `activeKeyName` required; unknown active key
  name, non-boolean flags or non-binary resource id -> typed
  `400 ManagedStorageInvalidBody`. Existing name -> atomic
  `409 ManagedStorageAccountNameAlreadyExists` (ONE :ets.insert_new — the
  create-on-existing silent overwrite is structurally impossible).
  """
  @spec create(binary, binary | Plug.Conn.t(), map) ::
          {:ok, 201, map} | {:error, 400 | 409, map}
  def create(name, conn_or_host, body_params) do
    ensure_table()

    host =
      case conn_or_host do
        %Plug.Conn{host: host} -> host
        host when is_binary(host) -> host
      end

    with :ok <- validate_create_body(body_params) do
      record = account_record(name, host, body_params)

      case :ets.insert_new(@table, {name, record}) do
        true -> {:ok, 201, record}
        false -> {:error, 409, error("ManagedStorageAccountNameAlreadyExists")}
      end
    end
  end

  defp validate_create_body(body) when is_map(body) do
    rid = Map.get(body, "storageAccountResourceId")
    akn = Map.get(body, "activeKeyName")
    arg = Map.get(body, "autoRegenerateKey", true)

    cond do
      not is_binary(rid) or rid == "" ->
        {:error, 400, error("ManagedStorageInvalidBody")}

      akn not in ["key1", "key2"] ->
        {:error, 400, error("ManagedStorageInvalidBody")}

      not is_boolean(arg) ->
        {:error, 400, error("ManagedStorageInvalidBody")}

      true ->
        :ok
    end
  end

  defp validate_create_body(_), do: {:error, 400, error("ManagedStorageInvalidBody")}

  defp account_record(name, host, body) do
    now = System.system_time(:second)

    %{
      "id" => "https://#{host}:8443/managedstorage/#{name}",
      "name" => name,
      "storageAccountResourceId" => body["storageAccountResourceId"],
      "activeKeyName" => body["activeKeyName"],
      "autoRegenerateKey" => Map.get(body, "autoRegenerateKey", true),
      "attributes" => %{
        "enabled" => get_in(body, ["storageAccountAttributes", "enabled"]) || true,
        "created" => now,
        "updated" => now,
        "recoveryLevel" => "Purgeable"
      },
      "key1" => fresh_key(),
      "key2" => fresh_key()
    }
  end

  defp fresh_key, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode64()

  # ---------------------------------------------------------------------------
  # Get / list
  # ---------------------------------------------------------------------------

  @doc """
  `GET /managedstorage/:name`. Unknown or soft-deleted name -> typed
  `404 ManagedStorageAccountNotFound`.
  """
  @spec get(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} -> {:ok, 200, record}
      :error -> {:error, 404, error("ManagedStorageAccountNotFound")}
    end
  end

  @doc """
  `GET /managedstorage`. Value list; soft-deleted rows are omitted by
  construction (tuple-keyed rows never match the binary-key list walk).
  """
  @spec list :: {:ok, 200, map}
  def list do
    ensure_table()
    {:ok, 200, %{"value" => Enum.sort_by(Store.list(@table), & &1["name"])}}
  end

  # ---------------------------------------------------------------------------
  # Soft delete / recover / purge (deleted-managed-storage class)
  # ---------------------------------------------------------------------------

  @doc """
  `DELETE /managedstorage/:name`. Soft delete: the live row moves to the
  `{:deleted, name}` tuple row (same table) and the response is the deleted
  bundle (id/attributes + recoveryId/deletedDate/scheduledPurgeDate). Live
  GET then 404s by construction. Unknown name -> typed 404.
  """
  @spec delete(binary) :: {:ok, 200, map} | {:error, 404, map}
  def delete(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} ->
        now = System.system_time(:second)

        bundle = %{
          "id" => record["id"],
          "name" => name,
          "storageAccountResourceId" => record["storageAccountResourceId"],
          "activeKeyName" => record["activeKeyName"],
          "autoRegenerateKey" => record["autoRegenerateKey"],
          "recoveryId" => record["id"] <> "/deleted",
          "deletedDate" => now,
          "scheduledPurgeDate" => now + 60 * 60 * 24 * 7
        }

        :ets.delete(@table, name)
        Store.put(@table, {:deleted, name}, bundle)
        {:ok, 200, bundle}

      :error ->
        {:error, 404, error("ManagedStorageAccountNotFound")}
    end
  end

  @doc """
  `GET /deletedmanagedstorage` -> value list of deleted bundles.
  """
  @spec list_deleted :: {:ok, 200, map}
  def list_deleted do
    ensure_table()

    deleted =
      @table
      |> Store.list_all()
      |> Enum.filter(fn v -> is_map(v) and match?(%{"recoveryId" => _}, v) end)
      |> Enum.sort_by(& &1["name"])

    {:ok, 200, %{"value" => deleted}}
  end

  @doc """
  `GET /deletedmanagedstorage/:name` -> deleted bundle. Unknown -> typed
  `404 ManagedStorageAccountNotFound`.
  """
  @spec get_deleted(binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_deleted(name) do
    ensure_table()

    case Store.get(@table, {:deleted, name}) do
      {:ok, bundle} -> {:ok, 200, bundle}
      :error -> {:error, 404, error("ManagedStorageAccountNotFound")}
    end
  end

  @doc """
  `POST /deletedmanagedstorage/:name/recover` -> restores the live account
  (200 ManagedStorageAccount) and drops the deleted bundle. Unknown bundle ->
  typed `404 ManagedStorageAccountDeleted`.
  """
  @spec recover(binary) :: {:ok, 200, map} | {:error, 404, map}
  def recover(name) do
    ensure_table()

    case Store.get(@table, {:deleted, name}) do
      {:ok, bundle} ->
        record =
          bundle
          |> Map.drop(["recoveryId", "deletedDate", "scheduledPurgeDate"])
          |> Map.put("attributes", %{
            "enabled" => true,
            "created" => System.system_time(:second),
            "updated" => System.system_time(:second),
            "recoveryLevel" => "Recoverable"
          })
          |> Map.put("key1", fresh_key())
          |> Map.put("key2", fresh_key())

        :ets.delete(@table, {:deleted, name})
        Store.put(@table, name, record)
        {:ok, 200, record}

      :error ->
        {:error, 404, error("ManagedStorageAccountDeleted")}
    end
  end

  @doc """
  `POST /deletedmanagedstorage/:name/purge` -> 204. Unknown bundle -> typed
  `404 ManagedStorageAccountDeleted`.
  """
  @spec purge(binary) :: {:ok, 204, map} | {:error, 404, map}
  def purge(name) do
    ensure_table()

    case Store.get(@table, {:deleted, name}) do
      {:ok, _bundle} ->
        :ets.delete(@table, {:deleted, name})
        {:ok, 204, %{}}

      :error ->
        {:error, 404, error("ManagedStorageAccountDeleted")}
    end
  end

  # ---------------------------------------------------------------------------
  # Keys: get / regenerate (active key selection)
  # ---------------------------------------------------------------------------

  @doc """
  `GET /managedstorage/:name/keys` -> the emulator's two storage account keys
  with the active key named (`activeKeyName`); typed 404 for unknown account.
  """
  @spec keys(binary) :: {:ok, 200, map} | {:error, 404, map}
  def keys(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} ->
        {:ok, 200,
         %{
           "activeKeyName" => record["activeKeyName"],
           "key1" => record["key1"],
           "key2" => record["key2"]
         }}

      :error ->
        {:error, 404, error("ManagedStorageAccountNotFound")}
    end
  end

  @doc """
  `POST /managedstorage/:name/regeneratestorageaccountkey`. Azure 2016-10-01
  contract: the key named by `activeKeyName` is replaced with fresh material,
  then the active key flips to the OTHER key. `autoRegenerateKey: false` ->
  typed `400 ManagedStorageAccountNotRegenerated`. Unknown account -> typed
  404.
  """
  @spec regenerate_key(binary, binary | Plug.Conn.t(), map) ::
          {:ok, 200, map} | {:error, 400 | 404, map}
  def regenerate_key(name, _conn_or_host \\ nil, _body_params \\ %{}) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} ->
        if record["autoRegenerateKey"] == false do
          {:error, 400, error("ManagedStorageAccountNotRegenerated")}
        else
          now = System.system_time(:second)
          old_active = record["activeKeyName"]
          new_active = if old_active == "key1", do: "key2", else: "key1"

          updated =
            record
            |> Map.put(old_active, fresh_key())
            |> Map.put("activeKeyName", new_active)
            |> put_in(["attributes", "updated"], now)

          Store.put(@table, name, updated)
          {:ok, 200, updated}
        end

      :error ->
        {:error, 404, error("ManagedStorageAccountNotFound")}
    end
  end

  # ---------------------------------------------------------------------------
  # SAS definitions
  # ---------------------------------------------------------------------------

  @doc """
  `PUT /managedstorage/:name/sas/:sasdef`. Body `{"templateUri": "..."}`.
  Unknown account -> typed 404; missing/non-binary templateUri -> typed
  `400 ManagedStorageInvalidBody`; existing definition -> atomic 409
  `SasDefinitionNameAlreadyExists`. Validated definition is stored and
  returned 201.
  """
  @spec put_sas(binary, binary, binary | Plug.Conn.t(), map) ::
          {:ok, 201, map} | {:error, 400 | 404 | 409, map}
  def put_sas(account, sas_def, conn_or_host, body_params) do
    ensure_table()

    host =
      case conn_or_host do
        %Plug.Conn{host: host} -> host
        host when is_binary(host) -> host
      end

    case Store.get(@table, account) do
      {:ok, _acct} ->
        template = Map.get(body_params || %{}, "templateUri")

        if not is_binary(template) or template == "" do
          {:error, 400, error("ManagedStorageInvalidBody")}
        else
          record = %{
            "id" => "https://#{host}:8443/managedstorage/#{account}/sas/#{sas_def}",
            "sasDefinition" => sas_def,
            "templateUri" => template,
            "attributes" => %{
              "created" => System.system_time(:second),
              "updated" => System.system_time(:second),
              "enabled" => true
            }
          }

          case :ets.insert_new(@table, {{:sas, account, sas_def}, record}) do
            true -> {:ok, 201, record}
            false -> {:error, 409, error("SasDefinitionNameAlreadyExists")}
          end
        end

      :error ->
        {:error, 404, error("ManagedStorageAccountNotFound")}
    end
  end

  @doc """
  `GET /managedstorage/:name/sas` -> list of SAS definitions for the account
  (`{"value": [...]}`); unknown account -> typed 404.
  """
  @spec list_sas(binary) :: {:ok, 200, map} | {:error, 404, map}
  def list_sas(account) do
    ensure_table()

    if Store.get(@table, account) == :error do
      {:error, 404, error("ManagedStorageAccountNotFound")}
    else
      defs =
        @table
        |> Store.list_all()
        |> Enum.filter(fn v -> is_map(v) and is_binary(v["sasDefinition"]) end)
        |> Enum.filter(fn v ->
          String.contains?(v["id"], "/managedstorage/#{account}/sas/")
        end)
        |> Enum.sort_by(& &1["sasDefinition"])

      {:ok, 200, %{"value" => defs}}
    end
  end

  @doc """
  `GET /managedstorage/:name/sas/:sasdef` -> stored SasDefinition; unknown
  account OR definition -> typed `404 SasDefinitionNotFound`.
  """
  @spec get_sas(binary, binary) :: {:ok, 200, map} | {:error, 404, map}
  def get_sas(account, sas_def) do
    ensure_table()

    case Store.get(@table, {:sas, account, sas_def}) do
      {:ok, record} -> {:ok, 200, record}
      :error -> {:error, 404, error("SasDefinitionNotFound")}
    end
  end

  @doc """
  `DELETE /managedstorage/:name/sas/:sasdef` -> 204. Unknown -> typed
  `404 SasDefinitionNotFound`.
  """
  @spec delete_sas(binary, binary) :: {:ok, 204, map} | {:error, 404, map}
  def delete_sas(account, sas_def) do
    ensure_table()

    case Store.get(@table, {:sas, account, sas_def}) do
      {:ok, _record} ->
        :ets.delete(@table, {:sas, account, sas_def})
        {:ok, 204, %{}}

      :error ->
        {:error, 404, error("SasDefinitionNotFound")}
    end
  end

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  defp error(code) do
    %{"error" => %{"code" => code}}
  end
end
