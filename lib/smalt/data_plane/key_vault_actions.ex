defmodule Smalt.DataPlane.KeyVaultActions do
  @moduledoc """
  Key Vault / Managed HSM data-plane crypto actions over the `:smalt_vault_keys`
  Store table (created by the `/keys/:name/create` route in `EgressRouter`).

  Wire surface (mounted on 8443; route handlers live in `EgressRouter`):
  - `POST /keys/:name/encrypt`   -> `encrypt/2`    (alg: "RSA-OAEP-256" | "A256GCM")
  - `POST /keys/:name/decrypt`   -> `decrypt/2`
  - `POST /keys/:name/sign`      -> `sign/2`       (alg: "RS256" | "PS256")
  - `POST /keys/:name/verify`    -> `verify/2`
  - `POST /keys/:name/wrapKey`   -> `wrap_key/2`
  - `POST /keys/:name/unwrapKey` -> `unwrap_key/2`
  - `POST /keys/:name/rotate`    -> `rotate_key/2`  (new version, same policy)
  - `GET  /keys`                 -> `list_keys/0`
  - `GET  /keys/:name/versions`  -> `list_versions/1`

  ## Wiring seams (for the route handlers in `EgressRouter`)

  Every function returns the `{:ok, status, body}` / `{:error, status, body}`
  tuples sibling data-plane modules use, so a handler is one `case`:

      case KeyVaultActions.encrypt(name, conn.body_params) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end

  The `GET /keys/:name` fetch and `POST /keys/:name/create`/`/release` routes
  already exist in `EgressRouter` over the same `:smalt_vault_keys` table and
  are unchanged by this module.

  ## Key material

  Keys are derived material:

  - RSA kty (`RSA`, `RSA-HSM`): a 2048-bit keypair is generated once per key
    name at first crypto use (`:public_key.generate_key`), DER-encoded, and
    cached in the Store row under `"key_material"`. Subsequent operations
    reuse the cached pair — same key for the life of the row.
  - oct kty (`oct`, `oct-HSM`): a 32-byte AES-256 key is derived deterministically
    as SHA-256("smalt-vault-derived:" <> key name) — no stored secret bytes.

  AES-GCM (`A256GCM`) uses a random 12-byte IV per operation, so ciphertexts
  are non-deterministic by construction (same for RSA-OAEP-256).

  ## Wire encoding

  All `value`/`digest`/`signature`/`iv`/`tag` fields are base64url without
  padding on output, per the real KV wire contract. Inputs accept both
  base64url and standard base64 for compatibility.

  ## Release policy

  Every operation is gated on the key's release policy `allowed_operations` /
  `allowedOperations` list; a record without a policy allows the default full
  set `["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]`.
  An operation outside the list is refused with
  `403 {"error":{"code":"OperationNotAllowed"}}` (real Azure KV status).
  """

  alias Smalt.DataPlane.KvPss
  alias Smalt.Store

  @default_ops ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]

  # ---------------------------------------------------------------------------
  # Identity-plane profile read sites (AZB-08)
  # ---------------------------------------------------------------------------

  @doc """
  The Key Vault data-plane API version served on `/:keys`+`/secrets` routes —
  `config :smalt, :keyvault, api_version: "7.4"` (identity-plane profile,
  config/env/az_prod_identity.exs). Default "7.4" when the profile is not
  loaded (`:all` boot), so the default boot is byte-identical. Consumed by
  the AKV api-version gate in `EgressRouter` (refusal-message example) and
  by the identity-plane court.
  """
  @spec api_version :: binary()
  def api_version do
    Keyword.get(Smalt.Config.keyvault(), :api_version, "7.4")
  end

  @doc """
  The Key Vault challenge posture — `config :smalt, :keyvault,
  challenge_mode: :strict_bearer`. See `Smalt.Auth.Bearer.kv_challenge_mode/0`
  (the single read surface the router consumes); this accessor exists so the
  profile key has one named reader per surface, matching `api_version/0`.
  """
  @spec challenge_mode :: :strict_bearer | atom()
  def challenge_mode do
    Keyword.get(Smalt.Config.keyvault(), :challenge_mode, :strict_bearer)
  end

  # ---------------------------------------------------------------------------
  # Encrypt / decrypt
  # ---------------------------------------------------------------------------

  @doc """
  `POST /keys/:name/encrypt`. Body `{"alg": ..., "value": base64}`. RSA keys
  use RSA-OAEP-256, oct keys use AES-256-GCM. Returns
  `{:ok, 200, %{"value" => ciphertext-b64, "kid" => kid}}`.
  """
  def encrypt(name, params, version \\ nil),
    do: public_key_op(name, "encrypt", params, version, &do_encrypt/3)

  @doc """
  `POST /keys/:name/:version/decrypt`. Inverse of `encrypt/2..3`. Returns
  `{:ok, 200, %{"value" => plaintext-b64, "kid" => kid}}`.
  """
  def decrypt(name, params, version \\ nil),
    do: secret_key_op(name, "decrypt", params, version, &do_decrypt/3)

  @doc """
  `POST /keys/:name/wrapKey`. Same mechanics as `encrypt/2`.
  """
  def wrap_key(name, params, version \\ nil),
    do: public_key_op(name, "wrapKey", params, version, &do_encrypt/3)

  @doc """
  `POST /keys/:name/unwrapKey`. Same mechanics as `decrypt/2`.
  """
  def unwrap_key(name, params, version \\ nil),
    do: secret_key_op(name, "unwrapKey", params, version, &do_decrypt/3)

  # ---------------------------------------------------------------------------
  # Sign / verify
  # ---------------------------------------------------------------------------

  @doc """
  `POST /keys/:name/sign`. Body `{"alg": "RS256" | "PS256", "digest":
  base64url-of-SHA-256}` (real contract) or `"value": b64` pre-image (compat,
  digested server-side). Returns
  `{:ok, 200, %{"value" => signature-b64url, "kid" => kid}}`.
  """
  def sign(name, params, version \\ nil),
    do: secret_key_op(name, "sign", params, version, &do_sign/3)

  @doc """
  `POST /keys/:name/verify`. Body `{"alg", "digest", "value": signature}`
  (real contract) or `"value": pre-image, "signature": sig` (compat). Returns
  `{:ok, 200, %{"value" => boolean, "kid" => kid}}` (KeyVerifyResult) with
  `"valid"` kept as a compat alias — a bad signature is a 200 with
  `"value": false`, not an error.
  """
  def verify(name, params, version \\ nil),
    do: public_key_op(name, "verify", params, version, &do_verify/3)

  # ---------------------------------------------------------------------------
  # List
  # ---------------------------------------------------------------------------

  @doc """
  `GET /keys`. All key records in the `:smalt_vault_keys` table, key order.

  Disclosed (lane 91/90 KV-TLS mounting): the same table also holds SKR's
  `skr-version:`/`skr-jti:` counter integers (Store.update_counter), so
  non-map entries are skipped — a release on any key otherwise 500s every
  subsequent `GET /keys`.
  """
  def list_keys do
    {:ok, 200,
     %{
       "value" =>
         Enum.flat_map(Store.list(:smalt_vault_keys), fn
           # GAP-A2-08/10: skip per-version rows ({name, version} keyed).
           %{"is_version_row" => true} -> []
           %{} = record -> [public_record(record)]
           _ -> []
         end)
     }}
  end

  @doc """
  `GET /keys/:name/versions`. Every version of `name`, newest first, as public
  key records (one per `{name, version}` row the create route stores). Older
  rows missing from the table fall back to the current record. Unknown key ->
  404 KeyNotFound.
  """
  def list_versions(name) do
    case fetch(name) do
      {:ok, %{"versions" => versions} = record} when is_list(versions) and versions != [] ->
        items =
          Enum.map(versions, fn version ->
            case Store.get(:smalt_vault_keys, {name, version}) do
              {:ok, version_record} -> public_record(version_record)
              :error -> public_record(record)
            end
          end)

        {:ok, 200, %{"value" => items}}

      {:ok, record} ->
        {:ok, 200, %{"value" => [public_record(record)]}}

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  # ---------------------------------------------------------------------------
  # Rotate
  # ---------------------------------------------------------------------------

  @doc """
  `POST /keys/:name/rotate` (Azure parity). Mints a NEW version of `name` from
  the SAME policy — kty, key_ops and release_policy are carried from the
  current record; the old version rows and their material are retained
  untouched. Response is the new version's public key bundle (KeyBundle of the
  latest version, `kid` carrying the new version suffix). Unknown key ->
  404 KeyNotFound.

  RSA: a fresh 2048-bit keypair is generated per rotation (DER on the new
  version's row). oct: material is the deterministic per-version derivation
  (`derive_oct_key/2`), so only the JWK `k` changes. Not gated on the release
  policy `allowed_operations` — rotation is a management-plane lifecycle op in
  the real contract, not a crypto op.
  """
  def rotate_key(name, _params \\ nil) do
    case fetch(name) do
      {:ok, record} ->
        version = Integer.to_string(System.unique_integer([:positive]))
        kid = "https://#{kid_authority(record)}/keys/#{name}/#{version}"

        {jwk_fields, key_material} =
          case kty(record) do
            kty when kty in ["RSA", "RSA-HSM"] ->
              key = :public_key.generate_key({:rsa, 2048, 65537})
              der = :public_key.der_encode(:RSAPrivateKey, key)

              # KD-105 close: JWK export rides KvPss.jwk_public — n/e plus the
              # `alg: PS256` stamp so external verifiers pick PSS/saltlen 32.
              case KvPss.jwk_public(der) do
                {:ok, jwk} ->
                  {Map.take(jwk, ["n", "e", "alg"]), der}

                {:error, _} ->
                  {:error, 400, bad_request("InvalidParameter", "bad key material")}
              end

            kty when kty in ["oct", "oct-HSM"] ->
              {%{
                 "k" =>
                   Base.url_encode64(derive_oct_key(name, version), padding: false)
               }, nil}

            other ->
              {:error, 400, bad_request("UnsupportedKeyType", "kty #{other} is not supported")}
          end

        case jwk_fields do
          %{} = fields ->
            now = System.system_time(:second)

            new_key =
              record["key"]
              |> Map.take(["kty", "key_ops"])
              |> Map.merge(fields)
              |> Map.put("kid", kid)

            new_record = %{
              "kid" => kid,
              # newest first (create's `&(&1 ++ prior_versions)` keeps the
              # newest at the head — rotate prepends the same way).
              "versions" => [version | Map.get(record, "versions", [])],
              "key" => new_key,
              "attributes" =>
                record["attributes"]
                |> Map.put("created", now)
                |> Map.put("updated", now),
              "release_policy" => record["release_policy"],
              "key_material" => key_material
            }

            Store.put(:smalt_vault_keys, name, new_record)

            Store.put(
              :smalt_vault_keys,
              {name, version},
              Map.put(new_record, "is_version_row", true)
            )

            {:ok, 200, public_record(new_record)}

          error ->
            error
        end

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  # The kid authority is reused verbatim (host AND port) so a rotated kid stays
  # same-origin as its parent's.
  defp kid_authority(record) do
    case record["kid"] do
      "https://" <> rest -> hd(String.split(rest, "/"))
      _ -> "smalt-vault"
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete / recover / purge (keys)
  # ---------------------------------------------------------------------------

  @deleted_table :smalt_vault_deleted_keys
  @retention_seconds 90 * 24 * 3600

  # Lazy table creation (mirrors BlobStorage.ensure_policy_table): the table is
  # not in Store.@tables (shared file), so it is provisioned on first use. A
  # Store restart recreates live tables only — deleted-bundle state is sim-state.
  #
  # KD-117 ROOT CAUSE (shadow-table heir class, mirrors Policy.ensure_tables/0):
  # the first creator is a Bandit request task — without an heir the table DIES
  # with that request process and every later request sees a fresh table
  # (witnessed: DELETE /keys 200 then GET /deletedkeys 404 on the same beam).
  # Heir to :init (permanent, node-local) makes the table outlive its creator;
  # the ArgumentError rescue keeps the create race fail-safe when several
  # requests race the first insert.
  @doc false
  def ensure_deleted_table do
    if :ets.info(@deleted_table) == :undefined do
      try do
        :ets.new(@deleted_table, [
          :ordered_set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  `DELETE /keys/:name` (soft delete). Removes the key from the normal surface
  (subsequent `GET /keys/:name` and crypto ops see 404 KeyNotFound) and moves
  it to the deleted-keys table with `recoveryId`, `deletedDate` and
  `scheduledPurgeDate` (epoch seconds, 90-day retention) per the real Azure
  deleted-key bundle contract. Returns the public deleted-key bundle (no
  `key_material`).
  """
  def delete_key(name) do
    ensure_deleted_table()

    case fetch(name) do
      {:ok, record} ->
        now = System.system_time(:second)

        # Version rows ({name, version}) ride along in the deleted record so a
        # recover restores the exact material each version had.
        {version_rows, record} = Map.pop(record, "version_rows", %{})
        version_rows = Map.put(version_rows, :live, fetch_version_rows(name, record))

        deleted =
          record
          |> Map.put("deletedDate", now)
          |> Map.put("scheduledPurgeDate", now + @retention_seconds)
          |> Map.put("recoveryId", recovery_id(record, name))
          |> Map.put("version_rows", version_rows)

        Enum.each(Map.get(version_rows, :live) || %{}, fn {version, _row} ->
          Store.delete(:smalt_vault_keys, {name, version})
        end)

        Store.delete(:smalt_vault_keys, name)
        Store.put(@deleted_table, name, deleted)

        {:ok, 200, public_deleted_record(deleted)}

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  @doc """
  `GET /deletedkeys/:name`. The deleted-key bundle (wire fields
  `recoveryId`, `deletedDate`, `scheduledPurgeDate`). Unknown or purged key
  -> 404 KeyNotFound. The NORMAL path (`GET /keys/:name`) 404s for a
  soft-deleted key by construction — the live row is gone.
  """
  def get_deleted_key(name) do
    ensure_deleted_table()

    case Store.get(@deleted_table, name) do
      {:ok, deleted} -> {:ok, 200, public_deleted_record(deleted)}
      :error -> {:error, 404, key_not_found()}
    end
  end

  @doc """
  `GET /deletedkeys`. All deleted-key bundles, key order.
  """
  def list_deleted_keys do
    ensure_deleted_table()

    {:ok, 200,
     %{
       "value" =>
         Enum.flat_map(Store.list(@deleted_table), fn
           %{} = record -> [public_deleted_record(record)]
           _ -> []
         end)
     }}
  end

  @doc """
  `POST /deletedkeys/:name/recover`. Restores the soft-deleted key to the
  live surface (including its version rows and their key material); the
  deleted entry is removed. Unknown or purged key -> 404 KeyNotFound.
  """
  def recover_deleted_key(name) do
    ensure_deleted_table()

    case Store.get(@deleted_table, name) do
      {:ok, deleted} ->
        {version_rows, deleted} = Map.pop(deleted, "version_rows", %{})
        restored = Map.drop(deleted, ["deletedDate", "scheduledPurgeDate", "recoveryId"])
        Store.put(:smalt_vault_keys, name, restored)

        # SHIM-COURT R4/D1: recover must re-put the live version rows, not skip them.
        Enum.each(version_rows || %{}, fn
          {:live, live_rows} ->
            Enum.each(live_rows || %{}, fn {version, row} ->
              Store.put(:smalt_vault_keys, {name, version}, Map.put(row, "is_version_row", true))
            end)

          {version, row} ->
            Store.put(:smalt_vault_keys, {name, version}, Map.put(row, "is_version_row", true))
        end)

        Store.delete(@deleted_table, name)
        {:ok, 200, public_record(restored)}

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  @doc """
  `POST /deletedkeys/:name/purge`. Permanent removal: the deleted entry and
  any residual version rows are gone — recover then 404s. A key flagged with
  purge protection (`"purge_protection": true` on the key record, wire shape
  of the real vault-level property) refuses with `409
  {"error":{"code":"Conflict"}}` — exactly the real contract.
  """
  def purge_deleted_key(name) do
    ensure_deleted_table()

    case Store.get(@deleted_table, name) do
      {:ok, deleted} ->
        if purge_protection?(deleted) do
          {:error, 409,
           %{
             "error" => %{
               "code" => "Conflict",
               "message" =>
                 "#{name} is protected against purge by a vault-level purge protection policy."
             }
           }}
        else
          Enum.each(Map.get(deleted, "version_rows", %{}) || %{}, fn
            :live -> :ok
            {version, _row} -> Store.delete(:smalt_vault_keys, {name, version})
          end)

          Store.delete(@deleted_table, name)
          {:ok, 204, %{}}
        end

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  # UNBLOCK-FIX (lane shim-court-repair, 2026-10-18): a sibling lane's
  # in-flight update_key_properties insertion consumed the `end` closing
  # purge_deleted_key; this restores the shared compile per the
  # compile-freeze SLA. Ownership of the feature stays with the editing lane.
  @doc """
  Updates key attributes / tags on an existing key or key version (PATCH /keys/:name or /keys/:name/:version).
  Returns `{:ok, 200, public_bundle}` on success or `{:error, 404, not_found}`.
  """
  def update_key_properties(name, params, version \\ nil) do
    target_version = if version in [nil, ""], do: nil, else: version

    case fetch(name, target_version) do
      {:ok, record} ->
        attrs = Map.get(record, "attributes", %{})
        new_attrs = Map.get(params, "attributes") || Map.get(params, "keyAttributes") || %{}
        merged_attrs = Map.merge(attrs, new_attrs)

        tags = Map.get(record, "tags", %{})
        new_tags = Map.get(params, "tags") || %{}
        merged_tags = Map.merge(tags, new_tags)

        updated_record =
          record
          |> Map.put("attributes", merged_attrs)
          |> Map.put("tags", merged_tags)

        # Update specific version row if versioned
        if target_version do
          Store.put(:smalt_vault_keys, {name, target_version}, updated_record)
        end

        # Always update root bare name record
        case Store.get(:smalt_vault_keys, name) do
          {:ok, root_record} ->
            updated_root =
              root_record
              |> Map.put("attributes", merged_attrs)
              |> Map.put("tags", merged_tags)

            Store.put(:smalt_vault_keys, name, updated_root)

          _ ->
            Store.put(:smalt_vault_keys, name, updated_record)
        end

        public_record = Map.drop(updated_record, ["key_material", "is_version_row", "versions"])
        {:ok, 200, public_record}

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  defp fetch_version_rows(name, record) do
    versions = record["versions"]

    if is_list(versions) do
      Map.new(versions, fn version ->
        case Store.get(:smalt_vault_keys, {name, version}) do
          {:ok, row} -> {version, row}
          :error -> {version, record}
        end
      end)
    else
      %{}
    end
  end

  # Real recoveryId shape: "https://{vault-host}/deletedkeys/{name}" — derived
  # from the key's kid host when present.
  defp recovery_id(record, name) do
    host =
      case record["kid"] do
        "https://" <> rest -> "https://" <> hd(String.split(rest, "/"))
        _ -> "https://smalt-vault"
      end

    "#{host}/deletedkeys/#{name}"
  end

  defp purge_protection?(record) do
    record["purge_protection"] == true or
      get_in(record, ["attributes", "purgeProtection"]) == true
  end

  # Retention is vault-level real-KV default (90d), already the keys constant.
  defp real_purge_date(now), do: now + @retention_seconds

  defp not_found(code), do: %{"error" => %{"code" => code}}

  defp public_deleted_secret(deleted) do
    Map.drop(deleted, ["is_deleted_secret"])
  end

  defp public_deleted_record(deleted) do
    deleted |> Map.drop(["key_material", "version_rows"]) |> public_record()
  end

  # GAP-A2-10: `version` is the named version from /keys/{name}/{version}/{action};
  # nil resolves the current (bare-name) row exactly as before.
  defp public_key_op(name, op, params, version, fun) do
    with_key(name, op, params, version, fun)
  end

  # Secret-key ops (decrypt/sign) need the private material; verify only needs
  # the public half but shares the same admission path.
  defp secret_key_op(name, op, params, version, fun) do
    with_key(name, op, params, version, fun)
  end

  defp with_key(name, op, params, version, fun) when is_map(params) do
    case fetch(name, version) do
      {:ok, record} ->
        with :ok <- check_allowed(record, op),
             {:ok, material} <- key_material(name, version, record) do
          fun.(record, params, material)
        end

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  defp with_key(_name, _op, _params, _version, _fun) do
    {:error, 400, bad_request("InvalidParameter", "request body must be a JSON object")}
  end

  defp fetch(name, nil), do: fetch(name)

  # SHIM-COURT: unknown version is a 404, not a silent fallback to the
  # bare-name row (real Azure KV contract).
  defp fetch(name, version) when version in [nil, ""], do: fetch(name)

  defp fetch(name, version) do
    case Store.get(:smalt_vault_keys, {name, version}) do
      {:ok, record} -> {:ok, record}
      :error -> :error
    end
  end

  defp fetch(name) do
    case Store.get(:smalt_vault_keys, name) do
      {:ok, record} -> {:ok, record}
      :error -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete / recover / purge (secrets) — KD-102
  # ---------------------------------------------------------------------------
  #
  # Deleted secrets share the `@deleted_table` with deleted keys, namespaced by
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
    ensure_deleted_table()

    case Store.get(:smalt_vault_secrets, name) do
      {:ok, record} ->
        now = System.system_time(:second)

        deleted =
          record
          |> Map.put("deletedDate", now)
          |> Map.put("scheduledPurgeDate", real_purge_date(now))
          |> Map.put("recoveryId", "https://smalt-vault/deletedsecrets/#{name}")
          |> Map.put("is_deleted_secret", true)

        Store.delete(:smalt_vault_secrets, name)
        Store.put(@deleted_table, {:secret, name}, deleted)

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
    ensure_deleted_table()

    case Store.get(@deleted_table, {:secret, name}) do
      {:ok, deleted} -> {:ok, 200, public_deleted_secret(deleted)}
      :error -> {:error, 404, not_found("SecretNotFound")}
    end
  end

  @doc """
  `GET /deletedsecrets`. All deleted-secret bundles, key order.
  """
  def list_deleted_secrets do
    ensure_deleted_table()

    {:ok, 200,
     %{
       "value" =>
         # list_all/1, not list/1: list/1 filters to the binary-key prefix
         # contract and silently drops tuple-keyed rows — deleted secrets ride
         # {:secret, name} tuple keys, so list/1 would return an empty listing
         # forever (witnessed live 2026-10-20: deleted secret present, list []).
         Enum.flat_map(Store.list_all(@deleted_table), fn
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
    ensure_deleted_table()

    case Store.get(@deleted_table, {:secret, name}) do
      {:ok, deleted} ->
        restored =
          deleted
          |> Map.drop(["deletedDate", "scheduledPurgeDate", "recoveryId", "is_deleted_secret"])

        Store.put(:smalt_vault_secrets, name, restored)
        Store.delete(@deleted_table, {:secret, name})
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
    ensure_deleted_table()

    case Store.get(@deleted_table, {:secret, name}) do
      {:ok, deleted} ->
        if purge_protection?(deleted) do
          {:error, 409,
           %{
             "error" => %{
               "code" => "Conflict",
               "message" =>
                 "#{name} is protected against purge by a vault-level purge protection policy."
             }
           }}
        else
          Store.delete(@deleted_table, {:secret, name})
          {:ok, 204, %{}}
        end

      :error ->
        {:error, 404, not_found("SecretNotFound")}
    end
  end

  # ---------------------------------------------------------------------------
  # Release policy gate
  # ---------------------------------------------------------------------------

  defp check_allowed(record, op) do
    allowed = allowed_operations(record)

    if op in allowed do
      :ok
    else
      # SHIM-COURT: real Azure KV refuses release-policy denials with
      # 403 Forbidden, not 400.
      {:error, 403,
       %{
         "error" => %{
           "code" => "OperationNotAllowed",
           "message" =>
             "Operation #{op} is not permitted by the key's release policy " <>
               "(allowed: #{Enum.join(allowed, ", ")})."
         }
       }}
    end
  end

  defp allowed_operations(%{"release_policy" => nil}), do: @default_ops

  defp allowed_operations(%{"release_policy" => policy}) when is_map(policy) do
    # SHIM-COURT: absent list falls open to defaults; an explicit EMPTY list
    # is deny-all (fail-closed) — empty and absent are distinguished.
    case policy["allowed_operations"] || policy["allowedOperations"] do
      ops when is_list(ops) -> Enum.map(ops, &to_string/1)
      _ -> @default_ops
    end
  end

  defp allowed_operations(_), do: @default_ops

  # ---------------------------------------------------------------------------
  # Key material
  # ---------------------------------------------------------------------------

  # GAP-A2-10: RSA DER is cached on the row it belongs to — the bare name row
  # for the current version, the {name, version} row for a named version — so
  # a versioned op never mutates a different version's material.
  defp key_material(name, version, record) do
    store_key = if version in [nil, ""], do: name, else: {name, version}

    case kty(record) do
      kty when kty in ["RSA", "RSA-HSM"] -> ensure_rsa(store_key, record)
      # SHIM-COURT: oct material is bound to name + version so distinct
      # versions hold distinct key bytes (bare-name ops keep the legacy
      # name-only derivation).
      kty when kty in ["oct", "oct-HSM"] -> {:ok, {:oct, derive_oct_key(name, version)}}
      other -> {:error, 400, bad_request("UnsupportedKeyType", "kty #{other} is not supported")}
    end
  end

  defp kty(record), do: get_in(record, ["key", "kty"]) || "RSA-HSM"

  # Deterministic per store key at first use: generated once, DER cached in the
  # Store row under "key_material", reused for the life of the row.
  defp ensure_rsa(store_key, record) do
    case record["key_material"] do
      der when is_binary(der) ->
        {:ok, {:rsa, :public_key.der_decode(:RSAPrivateKey, der)}}

      _ ->
        key = :public_key.generate_key({:rsa, 2048, 65537})
        der = :public_key.der_encode(:RSAPrivateKey, key)

        # SHIM-COURT: a materialized version row must be marked so list_keys/0
        # never surfaces it as a duplicate live key.
        record =
          case store_key do
            {_name, _version} ->
              record |> Map.put("key_material", der) |> Map.put("is_version_row", true)

            _name_only ->
              Map.put(record, "key_material", der)
          end

        Store.put(:smalt_vault_keys, store_key, record)
        {:ok, {:rsa, key}}
    end
  end

  @doc """
  Deterministic derived AES-256 material for `oct`/`oct-HSM` keys:
  `SHA-256("smalt-vault-derived:" <> name)` for the bare-name (current)
  surface. A named version length-prefixes the name —
  `SHA-256("smalt-vault-derived:" <> <<byte_size(name)::32>> <> name <> version)` —
  so a ":" in a key NAME can never collide with the {name, version} separator
  (a key literally named "a:v" derives different material than version "v" of
  key "a"). Distinct versions still derive distinct material. Public so the
  create route can project the JWK `k` field (disclosed dev-material
  derivation).
  """
  def derive_oct_key(name, version \\ nil)

  def derive_oct_key(name, version) when version in [nil, ""],
    do: :crypto.hash(:sha256, "smalt-vault-derived:" <> name)

  def derive_oct_key(name, version),
    do:
      :crypto.hash(:sha256, "smalt-vault-derived:" <> <<byte_size(name)::32>> <> name <> version)

  defp rsa_public({:rsa, key}), do: {:RSAPublicKey, elem(key, 2), elem(key, 3)}

  # ---------------------------------------------------------------------------
  # Crypto implementations
  # ---------------------------------------------------------------------------

  defp do_encrypt(record, params, material) do
    kid = record["kid"]

    with {:ok, plain} <- b64_field(params, "value"),
         {:ok, alg} <- encrypt_alg(material, params),
         :ok <- check_encrypt_size(plain, material) do
      {cipher, extra} =
        case material do
          {:rsa, _key} ->
            {:public_key.encrypt_public(plain, rsa_public(material), [
               {:rsa_padding, :rsa_pkcs1_oaep_padding},
               {:rsa_oaep_md, :sha256}
             ]), %{}}

          {:oct, aes_key} ->
            {ct, iv, tag} = aes_gcm_encrypt(aes_key, plain)
            {ct, %{"iv" => b64url_encode(iv), "tag" => b64url_encode(tag)}}
        end

      {:ok, 200,
       Map.merge(%{"value" => b64url_encode(cipher), "kid" => kid, "alg" => alg}, extra)}
    end
  rescue
    _ in [ErlangError, ArgumentError] ->
      {:error, 400, bad_request("InvalidValue", "value could not be encrypted")}
  end

  # RSA-OAEP(SHA-256) cannot encrypt plaintexts above the modulus ceiling;
  # fail with the real contract's 400 InvalidValue before hitting the NIF.
  # SHIM-COURT: mirrors do_decrypt's rescue so oversize is 400, never 500.
  defp check_encrypt_size(plain, {:rsa, key}) do
    max = byte_size(:binary.encode_unsigned(elem(key, 2))) - 32

    if byte_size(plain) > max do
      {:error, 400,
       bad_request("InvalidValue", "value exceeds maximum encryptable size of #{max} bytes")}
    else
      :ok
    end
  end

  defp check_encrypt_size(_plain, {:oct, _aes_key}), do: :ok

  defp do_decrypt(record, params, material) do
    kid = record["kid"]

    with {:ok, cipher} <- b64_field(params, "value"),
         {:ok, _alg} <- encrypt_alg(material, params) do
      plain =
        case material do
          {:rsa, key} ->
            :public_key.decrypt_private(cipher, key, [
              {:rsa_padding, :rsa_pkcs1_oaep_padding},
              {:rsa_oaep_md, :sha256}
            ])

          {:oct, aes_key} ->
            aes_gcm_decrypt(aes_key, params, cipher)
        end

      {:ok, 200, %{"value" => b64url_encode(plain), "kid" => kid}}
    end
  rescue
    _ in [ErlangError, ArgumentError] ->
      {:error, 400, bad_request("InvalidValue", "value could not be decrypted")}
  end

  # Real contract: `digest` is the base64url SHA-256 digest of the pre-image.
  # R177b: the real azure-keyvault-keys SDK sends the pre-hashed digest in the
  # `value` field (KeySignParameters(algorithm, value=digest)) — a 32-byte
  # decoded `value` IS the digest, re-hashing it double-hashes (R32's defect
  # resurfacing on the SDK wire shape). Compat pre-images are hashed
  # server-side; anything not exactly 32 bytes stays a pre-image. `digest`
  # wins when both are present.
  defp sign_digest(params) do
    case params["digest"] do
      d when is_binary(d) ->
        case b64_decode(d) do
          {:ok, digest} ->
            {:ok, digest}

          :error ->
            {:error, 400, bad_request("InvalidValue", "digest is not valid base64/base64url")}
        end

      _ ->
        case b64_field(params, "value") do
          {:ok, <<_::256>> = digest} -> {:ok, digest}
          {:ok, plain} -> {:ok, :crypto.hash(:sha256, plain)}
          error -> error
        end
    end
  end

  defp do_sign(record, params, {:rsa, key}) do
    kid = record["kid"]

    with {:ok, digest} <- sign_digest(params),
         {:ok, alg} <- sign_alg(params) do
      # SHIM-COURT (R32): `digest` arrives PRE-HASHED (RS256 contract).
      # A real digest-type re-hashes the input (double-hash defect); :none
      # alone omits the DigestInfo ASN.1 wrapper real RS256 requires — so the
      # EMSA-PKCS1-v1_5 DigestInfo prefix is prepended and signed raw.
      sha256_digestinfo =
        <<0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02,
          0x01, 0x05, 0x00, 0x04, 0x20>>

      with {:ok, sig} <-
             (case alg do
                "RS256" ->
                  {:ok,
                   :public_key.sign(sha256_digestinfo <> digest, :none, key,
                     rsa_padding: :rsa_pkcs1_padding
                   )}

               # KD-105 close: PS256 is externally verifiable — the wire digest is
               # PRE-HASHED, so the PSS encoding is built over the digest exactly
               # once (KvPss :prehashed, EMSA-PSS MGF1-SHA256 saltlen 32) and the
               # raw RSA op applied (OTP has no :none+PSS mode).
               "PS256" ->
                 KvPss.sign_pss(:public_key.der_encode(:RSAPrivateKey, key), digest,
                   prehashed: true
                 )
              end) do
        {:ok, 200, %{"value" => b64url_encode(sig), "kid" => kid, "alg" => alg}}
      end
    end
  end

  defp do_sign(_record, _params, {:oct, _}), do: {:error, 400, unsupported_alg_for_key_type()}

  # Real contract: signature rides `value`; `signature` kept as compat alias.
  defp verify_signature(params) do
    case params["signature"] || params["value"] do
      sig when is_binary(sig) -> b64_field_value(sig, "signature")
      _ -> {:error, 400, bad_request("InvalidParameter", "signature (or value) is required")}
    end
  end

  defp do_verify(record, params, {:rsa, key}) do
    kid = record["kid"]

    with {:ok, digest} <- sign_digest(params),
         {:ok, sig} <- verify_signature(params),
         {:ok, alg} <- sign_alg(params) do
      valid =
        try do
          result =
            case alg do
              # SHIM-COURT (R32): mirror do_sign — DigestInfo prefix + :none.
              "RS256" ->
                :public_key.verify(
                  <<0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04,
                    0x02, 0x01, 0x05, 0x00, 0x04, 0x20>> <> digest,
                  :none,
                  sig,
                  rsa_public({:rsa, key}),
                  rsa_padding: :rsa_pkcs1_padding
                )

              # KD-105 close: mirrors do_sign's KvPss prehashed path — same
              # EMSA-PSS encoding, fail-closed boolean.
              "PS256" ->
                KvPss.verify_pss(
                  :public_key.der_encode(:RSAPublicKey, rsa_public({:rsa, key})),
                  digest,
                  sig,
                  prehashed: true
                )
            end

          result == true
        rescue
          _ in [ErlangError, ArgumentError] -> false
        end

      # Real KeyVerifyResult is {"value": bool}; "valid" kept as compat alias.
      {:ok, 200, %{"value" => valid, "valid" => valid, "kid" => kid}}
    end
  end

  defp do_verify(_record, _params, {:oct, _}), do: {:error, 400, unsupported_alg_for_key_type()}

  # ---------------------------------------------------------------------------
  # AES-GCM (oct keys, A256GCM)
  # ---------------------------------------------------------------------------

  defp aes_gcm_encrypt(aes_key, plain) do
    iv = :crypto.strong_rand_bytes(12)
    {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key, iv, plain, "", 16, true)
    {cipher, iv, tag}
  end

  # Envelope: value is the GCM ciphertext; iv and tag ride the request body
  # (base64) as produced by the encrypt response.
  defp aes_gcm_decrypt(aes_key, params, cipher) do
    iv = decoded_field(params, "iv")
    tag = decoded_field(params, "tag")

    :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key, iv, cipher, "", tag, false)
  end

  # ---------------------------------------------------------------------------
  # Parameter handling
  # ---------------------------------------------------------------------------

  defp encrypt_alg({:rsa, _}, %{"alg" => "RSA-OAEP-256"}), do: {:ok, "RSA-OAEP-256"}
  defp encrypt_alg({:oct, _}, %{"alg" => "A256GCM"}), do: {:ok, "A256GCM"}

  defp encrypt_alg({:oct, _}, %{"alg" => "RSA-OAEP-256"}),
    do: {:error, 400, unsupported_alg_for_key_type()}

  defp encrypt_alg({:rsa, _}, %{"alg" => "A256GCM"}),
    do: {:error, 400, unsupported_alg_for_key_type()}

  defp encrypt_alg(_, %{"alg" => other}),
    do: {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg #{other}")}

  defp encrypt_alg(_, _), do: {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}

  defp sign_alg(%{"alg" => alg}) when alg in ["RS256", "PS256"], do: {:ok, alg}

  defp sign_alg(%{"alg" => other}),
    do: {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg #{other}")}

  defp sign_alg(_), do: {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}

  defp unsupported_alg_for_key_type do
    bad_request("InvalidAlgorithm", "algorithm not supported for this key type")
  end

  # Wire encoding is base64url without padding (real KV contract). Input
  # compat: standard base64 (padded, +/) is also accepted on decode.
  defp b64url_encode(bin), do: Base.url_encode64(bin, padding: false)

  # Total decode: base64url and standard base64, each padded or unpadded.
  # SDKs emit base64url unpadded; CLIs and curl users paste the other three.
  defp b64_decode(value) when is_binary(value) do
    with :error <- Base.url_decode64(value, padding: false),
         :error <- Base.url_decode64(value, padding: true),
         :error <- Base.decode64(value, padding: false),
         :error <- Base.decode64(value, padding: true) do
      :error
    end
  end

  defp b64_field(params, field, opts \\ []) do
    case params[field] || opts[:default] do
      value when is_binary(value) ->
        case b64_decode(value) do
          {:ok, decoded} ->
            {:ok, decoded}

          :error ->
            {:error, 400, bad_request("InvalidValue", "#{field} is not valid base64/base64url")}
        end

      _ ->
        {:error, 400, bad_request("InvalidParameter", "#{field} is required")}
    end
  end

  defp b64_field_value(value, field) do
    case b64_decode(value) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {:error, 400, bad_request("InvalidValue", "#{field} is not valid base64/base64url")}
    end
  end

  defp decoded_field(params, field) do
    case b64_decode(params[field] || "") do
      {:ok, decoded} -> decoded
      :error -> <<>>
    end
  end

  defp bad_request(code, message) do
    %{"error" => %{"code" => code, "message" => message}}
  end

  defp key_not_found do
    %{"error" => %{"code" => "KeyNotFound"}}
  end

  # Store rows carry the private DER under "key_material"; that never leaves
  # the vault — listings project the public record only. Internal bookkeeping
  # (is_version_row, versions) is stripped from every public emission path
  # (create/get/list/versions). release_policy stays PUBLIC (R111 reconcile of
  # R86's over-broad drop): the egress pin at egress_dispatch_test.exs:415
  # requires the create response to echo the admission policy back — SDK
  # clients read it to learn what the stored key may do. SHIM-COURT-KV86
  defp public_record(record) do
    Map.drop(record, ["key_material", "is_version_row", "versions"])
  end
end
