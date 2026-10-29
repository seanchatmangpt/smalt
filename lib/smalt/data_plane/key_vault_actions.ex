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
  - oct kty (`oct`): a 32-byte AES-256 key is derived deterministically
    as SHA-256("smalt-vault-derived:" <> key name) — no stored secret bytes.
  - oct-HSM kty (`oct-HSM`): REAL random material (`:crypto.strong_rand_bytes(32)`)
    per version, stored on the version's Store row under `"key_material"` and
    never exported in the JWK (HSM key material is non-exportable in the real
    contract). Distinct versions hold distinct bytes.
  - EC kty (`EC`, crv `P-256`/`P-384`): a real EC keypair is generated
    (`:crypto.generate_key(:ecdh, {:named_curve, ...})`), the private key DER-
    encoded and cached in the Store row under `"key_material"`. Sign/verify are
    ECDSA (`ES256`/`ES384`) with raw JWS `r||s` signatures on the wire; JWK
    export carries `crv`/`x`/`y`. EC keys refuse encrypt/wrap (real contract).

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

  # EC named curves: OTP curve atom, DER OID, coordinate width (bytes), the
  # digest paired with the JWS alg, and the wire alg itself.
  @ec_curves %{
    "P-256" => %{curve: :secp256r1, oid: {1, 2, 840, 10045, 3, 1, 7}, coord: 32, md: :sha256, alg: "ES256"},
    "P-384" => %{curve: :secp384r1, oid: {1, 3, 132, 0, 34}, coord: 48, md: :sha384, alg: "ES384"}
  }

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
  # Create (module-level seam; the HTTP route lives in EgressRouter)
  # ---------------------------------------------------------------------------

  @doc """
  Mints a new key record over the `:smalt_vault_keys` table — the module-level
  twin of the `POST /keys/:name/create` route (same record shape: bare-name row
  + one `is_version_row` row, `key_material` private on the row, public bundle
  returned). Supports the raised key types:

  - `kty: "EC"` (default crv `P-256`; `P-384` via `"crv"`): real keypair, JWK
    `crv`/`x`/`y` projected, private DER cached on the row.
  - `kty: "oct-HSM"`: fresh `:crypto.strong_rand_bytes(32)` material stored on
    the version row; NO `k` in the JWK (HSM material non-exportable).
  - `kty: "oct"`: legacy deterministic derivation, `k` projected.
  - `kty: "RSA"/"RSA-HSM"`: RSA row; material lazily generated at first use.

  Note: the HTTP create route (`EgressRouter.jwk_for_kty/3`, shared file) does
  not yet dispatch "EC" — it 400s UnsupportedKeyType until that seam adopts
  this function.
  """
  def create_key(name, params \\ %{}) when is_binary(name) and is_map(params) do
    kty = Map.get(params, "kty", "RSA-HSM")
    release_policy = Map.get(params, "release_policy")
    version = Integer.to_string(System.unique_integer([:positive]))
    kid = "https://smalt-vault/keys/#{name}/#{version}"

    with {:ok, jwk_fields, key_material} <- create_material(kty, name, version, params) do
      now = System.system_time(:second)

      key_record = %{
        "kid" => kid,
        "versions" => [version],
        "key" => Map.merge(%{"kid" => kid, "kty" => kty}, jwk_fields),
        "attributes" => %{
          "enabled" => true,
          "exportable" => not is_nil(release_policy),
          "created" => now
        },
        "release_policy" => release_policy,
        "key_material" => key_material
      }

      Store.put(:smalt_vault_keys, name, key_record)
      Store.put(:smalt_vault_keys, {name, version}, Map.put(key_record, "is_version_row", true))

      {:ok, 200, public_record(key_record)}
    end
  end

  defp create_material("EC", _name, _version, params) do
    crv = Map.get(params, "crv", "P-256")
    curve = Map.get(@ec_curves, crv)

    if curve do
      {pub_point, priv} = :crypto.generate_key(:ecdh, curve.curve)
      priv_rec = {:ECPrivateKey, 1, priv, {:namedCurve, curve.oid}, pub_point, <<>>}
      der = :public_key.der_encode(:ECPrivateKey, priv_rec)

      {:ok,
       Map.merge(%{"crv" => crv}, ec_point_jwk(crv, curve, pub_point)), der}
    else
      {:error, 400, bad_request("InvalidParameter", "unsupported EC crv #{crv}")}
    end
  end

  defp create_material("oct-HSM", _name, _version, _params) do
    {:ok, %{}, :crypto.strong_rand_bytes(32)}
  end

  defp create_material("oct", name, version, _params) do
    {:ok, %{"k" => Base.url_encode64(derive_oct_key(name, version), padding: false)}, nil}
  end

  defp create_material(kty, _name, _version, _params) when kty in ["RSA", "RSA-HSM"] do
    {:ok, %{}, nil}
  end

  defp create_material(kty, _name, _version, _params) do
    {:error, 400, bad_request("UnsupportedKeyType", "kty #{kty} is not supported")}
  end

  # ---------------------------------------------------------------------------
  # Rotation policy (Azure parity: GET/PUT /keys/{name}/rotationpolicy)
  # ---------------------------------------------------------------------------

  @rotation_action_types ["Rotate", "Notify"]
  @iso8601_duration_re ~r|^P(?!$)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+(\.\d+)?S)?)?$|

  @doc """
  `GET /keys/{name}/rotationpolicy` (Azure parity). Returns the stored policy
  or the default (no-op) policy when never set — real Azure returns 200 with
  an empty `lifetimeActions` default. Unknown key -> 404 KeyNotFound.
  """
  def get_rotation_policy(name) do
    case fetch(name) do
      {:ok, record} -> {:ok, 200, rotation_policy_view(record)}
      :error -> {:error, 404, key_not_found()}
    end
  end

  @doc """
  `PUT /keys/{name}/rotationpolicy` (Azure parity). Validates the
  KeyRotationPolicy body: `lifetimeActions` elements must be maps with
  `action.type` in Rotate|Notify; triggers use `timeAfterCreate` or
  `timeBeforeExpiry` holding ISO-8601 durations (P...T...); `attributes.
  expiryTime` is an RFC3339 string or nil. Malformed input is a typed 400
  BadRequest with no write. Unknown key -> 404 KeyNotFound.
  """
  def set_rotation_policy(name, params) when is_map(params) do
    case fetch(name) do
      {:ok, record} ->
        with {:ok, policy} <- validate_rotation_policy(params) do
          updated = Map.put(record, "rotation_policy", policy)
          Store.put(:smalt_vault_keys, name, updated)

          {:ok, 200, rotation_policy_view(updated)}
        end

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  def set_rotation_policy(_name, _params),
    do: {:error, 400, bad_request("InvalidParameter", "rotation policy body must be a JSON object")}

  defp rotation_policy_view(record) do
    policy = record["rotation_policy"]
    base = key_base_url(record)
    created = get_in(record, ["attributes", "created"])

    if policy do
      %{
        "id" => "#{base}/keys/rotationPolicy?api-version=#{api_version()}",
        "lifetimeActions" => policy["lifetimeActions"],
        "attributes" => %{
          "expiryTime" => get_in(policy, ["attributes", "expiryTime"]),
          "created" => created,
          "updated" => System.system_time(:second)
        }
      }
    else
      %{
        "id" => nil,
        "lifetimeActions" => [],
        "policyVersion" => nil,
        "attributes" => %{"expiryTime" => nil, "created" => created}
      }
    end
  end

  defp key_base_url(record) do
    case record["kid"] do
      "https://" <> rest -> "https://" <> hd(String.split(rest, "/"))
      _ -> "https://smalt-vault"
    end
  end

  defp validate_rotation_policy(%{"lifetimeActions" => actions} = params) when is_list(actions) do
    with :ok <- validate_expiry(get_in(params, ["attributes", "expiryTime"])),
         {:ok, validated} <- validate_lifetime_actions(actions) do
      {:ok, %{"lifetimeActions" => validated, "attributes" => %{"expiryTime" => get_in(params, ["attributes", "expiryTime"])}}}
    end
  end

  defp validate_rotation_policy(_other),
    do: {:error, 400, bad_request("InvalidParameter", "rotation policy requires a lifetimeActions array")}

  defp validate_expiry(nil), do: :ok

  # KD-COVERS: KD-12 — real AKV KeyRotationPolicy attributes.expiryTime is an
  # ISO-8601 DURATION ("P30D", per Azure key-rotation-policy grammar), not an
  # RFC3339 timestamp; the RFC3339-only gate 400'd every SDK-shaped rotation
  # policy body carrying an expiryTime. Duration shape reuses the trigger
  # duration validator; RFC3339 stays admitted for backward wire-compat.
  defp validate_expiry(e) when is_binary(e) do
    cond do
      Regex.match?(@iso8601_duration_re, e) -> :ok
      match?({:ok, _, _}, DateTime.from_iso8601(e)) -> :ok
      true -> {:error, 400, bad_request("InvalidParameter", "attributes.expiryTime must be an ISO-8601 duration (e.g. P30D) or an RFC3339 timestamp")}
    end
  end

  defp validate_expiry(_),
    do: {:error, 400, bad_request("InvalidParameter", "attributes.expiryTime must be an ISO-8601 duration (e.g. P30D) or an RFC3339 timestamp, or null")}

  defp validate_lifetime_actions(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn
      a, {:ok, acc} ->
        case validate_lifetime_action(a) do
          {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
          err -> {:halt, err}
        end

      _, err ->
        {:halt, err}
    end)
  end

  defp validate_lifetime_action(%{"action" => %{"type" => t}} = a) when t in @rotation_action_types do
    case trigger_of(a) do
      {:ok, trigger} -> {:ok, %{"trigger" => trigger, "action" => %{"type" => t}}}
      err -> err
    end
  end

  defp validate_lifetime_action(%{"action" => %{"type" => t}}),
    do: {:error, 400, bad_request("InvalidParameter", "lifetimeActions action.type #{inspect(t)} is not in [Rotate, Notify]")}

  defp validate_lifetime_action(_),
    do: {:error, 400, bad_request("InvalidParameter", "each lifetimeActions element requires action.type in [Rotate, Notify]")}

  defp trigger_of(%{"trigger" => %{} = t}) do
    cond do
      after_create = t["timeAfterCreate"] ->
        valid_duration?(after_create)
        |> result_of(%{"timeAfterCreate" => after_create})

      before_expiry = t["timeBeforeExpiry"] ->
        valid_duration?(before_expiry)
        |> result_of(%{"timeBeforeExpiry" => before_expiry})

      true ->
        {:ok, %{}}
    end
  end

  defp trigger_of(%{"trigger" => other}) when not is_map(other),
    do: {:error, 400, bad_request("InvalidParameter", "trigger must be an object")}

  defp trigger_of(_), do: {:ok, %{}}

  defp valid_duration?(s) when is_binary(s), do: Regex.match?(@iso8601_duration_re, s)
  defp valid_duration?(_), do: false

  defp result_of(true, value), do: {:ok, value}
  defp result_of(false, _), do: {:error, 400, bad_request("InvalidParameter", "trigger time must be an ISO-8601 duration (e.g. P30D)")}

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
  version's row). oct (soft): material is the deterministic per-version
  derivation (`derive_oct_key/2`), so only the JWK `k` changes. oct-HSM: FRESH
  random material per version (`:crypto.strong_rand_bytes(32)`), stored on the
  version row, no `k` in the JWK. EC: a fresh keypair with crv/x/y JWK and the
  new private DER on the new version's row. Not gated on the release
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

            # oct (soft) keeps the disclosed derivation; only the JWK `k`
            # changes per version (length-prefixed per-version derivation).
            "oct" ->
              {%{
                 "k" =>
                   Base.url_encode64(derive_oct_key(name, version), padding: false)
               }, nil}

            # oct-HSM rotates to FRESH random material per version (the raise:
            # derivation is the `oct` soft-key path only). The JWK carries no
            # "k" — HSM key material is non-exportable in the real contract.
            "oct-HSM" ->
              material = :crypto.strong_rand_bytes(32)
              {%{}, material}

            # EC rotates to a fresh keypair with a projected JWK (crv/x/y) and
            # the new private DER cached on the new version's row.
            "EC" ->
              crv = ec_crv(record)
              curve = Map.fetch!(@ec_curves, crv)
              {pub_point, priv} = :crypto.generate_key(:ecdh, curve.curve)
              priv_rec = {:ECPrivateKey, 1, priv, {:namedCurve, curve.oid}, pub_point, <<>>}
              der = :public_key.der_encode(:ECPrivateKey, priv_rec)

              jwk =
                Map.merge(
                  %{"kty" => "EC", "crv" => crv},
                  ec_point_jwk(crv, curve, pub_point)
                )

              {jwk, der}

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

  # w6bn: public-shape mirror of the router's public_secret_record — the
  # engine returns the wire shape directly so the route arm is 3 lines.
  defp public_secret_record(record) do
    Map.drop(record, ["value", "is_version_row", "versions", "created_seq"])
  end

  defp secret_not_found do
    %{
      "error" => %{
        "code" => "SecretNotFound",
        "message" => "A secret with (name/id) was not found in this key vault."
      }
    }
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
    # KD-S3 bookkeeping (versions index, captured version rows) never leaves
    # the vault on the deleted-secret bundle.
    Map.drop(deleted, ["is_deleted_secret", "versions", "version_rows", "created_seq"])
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
        with :ok <- check_enabled(record, op),
             :ok <- check_allowed(record, op),
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

  # ---------------------------------------------------------------------------
  # Backup / restore (wave-6 w6ab) — Azure KV shape over the SAME envelope
  # contract as VaultData's secret backup (KD-103), extended with the
  # versioned magic prefix + version-row capture:
  #   blob = @backup_magic <> "." <> Base64(JSON{checksum, bundle})
  #   bundle (key) = %{kind: "key", name, record, version_rows}
  #   bundle (cert) = %{kind: "certificate", name, record}
  # restore validates magic + checksum; garbage -> typed MalformedBackupBlob
  # (the Azure 400 face); live name conflict -> NameConflict (the 409 face)
  # unless force: true. Roundtrip law: backup(k) -> delete k -> restore ->
  # k byte-equivalent (root row + version rows + key material).
  # ---------------------------------------------------------------------------

  @backup_magic "SMALT-KVB1"

  @doc """
  `POST /keys/{name}/backup` face. Returns `{"value" => blob}` where blob is
  `SMALT-KVB1.<base64 JSON envelope>` carrying the root record, every version
  row (with private `key_material`) and an inner SHA-256 checksum.
  Unknown key -> `{:error, 404, KeyNotFound}`.
  """
  @spec backup_key(binary()) ::
          {:ok, 200, %{binary() => binary()}} | {:error, 404, map()}
  def backup_key(name) when is_binary(name) do
    case fetch(name) do
      {:ok, record} ->
        version_rows =
          record
          |> Map.get("versions", [])
          |> List.wrap()
          |> Map.new(fn version ->
            case Store.get(:smalt_vault_keys, {name, version}) do
              {:ok, row} -> {version, row}
              :error -> {version, record}
            end
          end)

        bundle = %{
          "kind" => "key",
          "name" => name,
          "record" => record,
          "version_rows" => version_rows
        }

        {:ok, 200, %{"value" => encode_backup(bundle)}}

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  @doc """
  `POST /keys/{name}/restore` face. `restore_key(blob)` / `restore_key(blob,
  force: true)`. Restores the encapsulated key under its own name (root row +
  every version row + private key material). Typed refusals: malformed or
  tampered blob -> `{:error, 400, MalformedBackupBlob}`; live name present
  -> `{:error, 409, NameConflict}` unless `force: true`. Fresh restore ->
  `{:ok, 201, ...}`; force-overwrite -> `{:ok, 200, ...}`.
  """
  @spec restore_key(binary(), keyword()) ::
          {:ok, 200 | 201, map()} | {:error, 400 | 409, map()}
  def restore_key(blob, opts \\ []) when is_binary(blob) and is_list(opts) do
    force = Keyword.get(opts, :force, false)

    with {:ok, bundle} <- decode_backup(blob, "key"),
         name when is_binary(name) and name != "" <- bundle["name"],
         record when is_map(record) <- bundle["record"] do
      case Store.get(:smalt_vault_keys, name) do
        {:ok, _existing} ->
          if force do
            write_key_rows(name, record, bundle["version_rows"] || %{})
            {:ok, 200, public_record(record)}
          else
            {:error, 409, bad_request("NameConflict", "key #{name} exists and is live; delete or purge it before restore")}
          end

        :error ->
          write_key_rows(name, record, bundle["version_rows"] || %{})
          {:ok, 201, public_record(record)}
      end
    else
      {:error, _c, _m} = refusal -> refusal
      nil -> {:error, 400, bad_request("MalformedBackupBlob", "backup bundle requires string \"name\" and map \"record\"")}
      _ -> {:error, 400, bad_request("MalformedBackupBlob", "backup blob failed validation")}
    end
  end

  # Byte-equivalence law: the restored rows are stored EXACTLY as backed up
  # (no re-stamping) so backup(k) -> delete -> restore -> k is byte-equal.
  defp write_key_rows(name, record, version_rows) do
    Store.put(:smalt_vault_keys, name, record)

    Enum.each(version_rows, fn {version, row} ->
      Store.put(:smalt_vault_keys, {name, version}, Map.put(row, "is_version_row", true))
    end)
  end

  # Shared envelope codec (kind-tagged so certificates ride the same shape).
  # Public cross-module seam (@doc false): Certificates reuses this codec so
  # there is ONE canonical SMALT-KVB1 envelope across keys/certificates.
  @doc false
  @spec kv_backup_encode(map()) :: binary()
  def kv_backup_encode(bundle), do: encode_backup(bundle)

  @doc false
  @spec kv_backup_decode(binary(), binary()) :: {:ok, map()} | {:error, 400, map()}
  def kv_backup_decode(blob, kind), do: decode_backup(blob, kind)

  defp encode_backup(bundle) do
    envelope = %{"checksum" => bundle_checksum(bundle), "bundle" => bundle}
    @backup_magic <> "." <> Base.encode64(Jason.encode!(envelope))
  end

  defp decode_backup(blob, kind) do
    with {:ok, _magic, json} <- split_magic(blob),
         {:ok, envelope} <- Smalt.JsonCompat.decode(json) do
      checksum = envelope["checksum"]
      bundle = envelope["bundle"]

      cond do
        not is_map(bundle) or is_nil(checksum) ->
          {:error, 400,
           bad_request(
             "MalformedBackupBlob",
             "backup blob is missing checksum or bundle fields"
           )}

        bundle_checksum(bundle) != checksum ->
          {:error, 400,
           bad_request(
             "MalformedBackupBlob",
             "backup blob checksum mismatch (tampered or truncated)"
           )}

        bundle["kind"] != kind ->
          {:error, 400,
           bad_request("MalformedBackupBlob", "backup blob kind mismatch (got #{inspect(bundle["kind"])}, want #{kind})")}

        true ->
          {:ok, bundle}
      end
    else
      {:error, :magic} ->
        {:error, 400, bad_request("MalformedBackupBlob", "backup blob magic prefix mismatch (not a SMALT-KVB1 blob)")}

      {:error, reason} ->
        {:error, 400,
         bad_request("MalformedBackupBlob", "backup blob is not base64-encoded JSON (#{inspect(reason)})")}
    end
  end

  defp split_magic(blob) do
    case :binary.split(blob, ".") do
      [@backup_magic, b64] ->
        case Base.decode64(b64) do
          {:ok, json} -> {:ok, @backup_magic, json}
          :error -> {:error, :base64}
        end

      _ ->
        {:error, :magic}
    end
  end

  defp bundle_checksum(bundle) do
    :crypto.hash(:sha256, Jason.encode!(bundle))
    |> Base.encode16(case: :lower)
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
          |> Map.put("scheduledPurgeDate", real_purge_date(now))
          |> Map.put("recoveryId", "https://smalt-vault/deletedsecrets/#{name}")
          |> Map.put("is_deleted_secret", true)
          |> Map.put("version_rows", version_rows)

        Enum.each(version_rows, fn {v, _row} ->
          Store.delete(:smalt_vault_secrets, {name, v})
        end)

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
          # KD-COVERS: KD-185 — purge drops the retained version rows for good.
          Enum.each(Map.get(deleted, "version_rows", %{}) || %{}, fn {v, _row} ->
            Store.delete(:smalt_vault_secrets, {name, v})
          end)

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

  # w6bn: a disabled key answers data-plane crypto ops with 403 Forbidden
  # (real Azure parity) while GET keeps answering 200 — the disabled
  # attribute gates OPERATIONS, not reads.
  defp check_enabled(record, op) when op in ["encrypt", "decrypt", "wrapKey", "unwrapKey", "sign", "verify"] do
    if Map.get(record["attributes"] || %{}, "enabled", true) == false do
      {:error, 403,
       %{
         "error" => %{
           "code" => "Forbidden",
           "message" =>
             "Operation #{op} is not permitted because the key is disabled " <>
               "(attributes.enabled == false)."
         }
       }}
    else
      :ok
    end
  end

  defp check_enabled(_record, _op), do: :ok

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
      # oct (soft) keeps the disclosed name-bound derivation; distinct versions
      # still derive distinct bytes (length-prefixed derivation).
      "oct" -> {:ok, {:oct, derive_oct_key(name, version)}}

      # oct-HSM carries REAL random material per version, stored on the version
      # row ("key_material"). Legacy rows (created before the raise, or via the
      # create route that projects a derived `k`) are lazily materialized on
      # first crypto use: fresh strong_rand_bytes, stored to the exact row.
      "oct-HSM" -> ensure_oct_hsm(store_key, record)
      "EC" -> ensure_ec(store_key, record)

      other -> {:error, 400, bad_request("UnsupportedKeyType", "kty #{other} is not supported")}
    end
  end

  defp kty(record), do: get_in(record, ["key", "kty"]) || "RSA-HSM"

  # oct-HSM: stored random material wins; missing material is minted once and
  # persisted so every later op (and every other version) sees stable bytes.
  defp ensure_oct_hsm(store_key, record) do
    case record["key_material"] do
      k when is_binary(k) and k != <<>> ->
        {:ok, {:oct, k}}

      _ ->
        k = :crypto.strong_rand_bytes(32)
        persist_material(store_key, record, k)
        {:ok, {:oct, k}}
    end
  end

  # Mirrors ensure_rsa's version-row marking.
  defp persist_material(store_key, record, material) do
    record =
      case store_key do
        {_name, _version} ->
          record |> Map.put("key_material", material) |> Map.put("is_version_row", true)

        _name_only ->
          Map.put(record, "key_material", material)
      end

    Store.put(:smalt_vault_keys, store_key, record)
    :ok
  end

  defp ec_crv(record), do: get_in(record, ["key", "crv"]) || "P-256"

  # EC: the private key is DER-cached on the row it belongs to (same law as
  # ensure_rsa) so a versioned op never mutates a different version's material.
  defp ensure_ec(store_key, record) do
    crv = ec_crv(record)
    curve = Map.get(@ec_curves, crv) || raise ArgumentError, "unsupported EC crv #{crv}"

    case record["key_material"] do
      der when is_binary(der) ->
        {:ok, {:ec, curve, :public_key.der_decode(:ECPrivateKey, der)}}

      _ ->
        {pub_point, priv} = :crypto.generate_key(:ecdh, curve.curve)
        priv_rec = {:ECPrivateKey, 1, priv, {:namedCurve, curve.oid}, pub_point, <<>>}
        der = :public_key.der_encode(:ECPrivateKey, priv_rec)
        persist_material(store_key, record, der)
        {:ok, {:ec, curve, priv_rec}}
    end
  end

  @doc """
  JWK public half for an EC key record: `crv`, `x`, `y` (base64url, fixed
  width, unsigned). Consumed by the create seam and by `rotate_key/2` so the
  wire shape matches the real JsonWebKey EC form.
  """
  def ec_jwk_public(%{} = record) do
    crv = ec_crv(record)
    curve = Map.fetch!(@ec_curves, crv)

    with {:ok, der} <- stored_der(record) do
      {:ECPrivateKey, _v, _priv, _params, pub_point, _attrs} =
        :public_key.der_decode(:ECPrivateKey, der)

      {:ok, Map.merge(%{"kty" => "EC", "crv" => crv}, ec_point_jwk(crv, curve, pub_point))}
    end
  end

  # Uncompressed point (0x04 || X || Y, fixed width per curve) -> JWK x/y.
  defp ec_point_jwk(_crv, curve, pub_point) do
    bits = curve.coord * 8

    <<4, x::unsigned-big-size(^bits), y::unsigned-big-size(^bits)>> = pub_point

    %{
      "x" => Base.url_encode64(<<x::unsigned-big-size(bits)>>, padding: false),
      "y" => Base.url_encode64(<<y::unsigned-big-size(bits)>>, padding: false)
    }
  end

  defp stored_der(%{"key_material" => der}) when is_binary(der), do: {:ok, der}
  defp stored_der(_), do: :error

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

  # KD-COVERS: KD-14 — RS256 signs EMSA-PKCS1-v1_5 over the SUBMITTED digest
  # (DigestInfo prefix + :none, no re-hash); external verifiers confirm
  # (hazmat Prehashed verify TRUE, tampered-sig control FALSE, bk26 receipt).
  defp do_sign(record, params, {:rsa, key}) do
    kid = record["kid"]

    with {:ok, digest} <- sign_digest(params),
         {:ok, alg} <- sign_alg(params),
         :ok <- alg_for_key_type(alg, {:rsa, key}) do
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

  # ECDSA: the wire digest is PRE-HASHED (same law as RS256) — ES256 signs the
  # SHA-256 digest with :sha256, ES384 the SHA-384 digest with :sha384. The DER
  # ECDSA-Sig-Value from :public_key.sign is flattened to the raw JWS `r||s`
  # form real KV returns (fixed width per curve, unsigned).
  defp do_sign(record, params, {:ec, curve, priv_rec}) do
    kid = record["kid"]

    with {:ok, digest} <- sign_digest(params),
         {:ok, alg} <- sign_alg(params),
         :ok <- alg_for_key_type(alg, {:ec, curve, nil}) do
      # KD-126: :crypto raises {:badarg, _, "Bad binary size for the algorithm"}
      # when the wire digest length does not match the curve's hash (ES384 over
      # a 32-byte digest, ES256 over 48, ...). That is a client-fault-shaped
      # request, not a server fault — answer the typed 400 face, never a 500.
      try do
        der_sig = :crypto.sign(:ecdsa, curve.md, {:digest, digest}, [elem(priv_rec, 2), curve.curve])
        {r, s} = ec_sig_der_decode(der_sig)
        bits = curve.coord * 8

        sig = <<r::unsigned-big-size(bits), s::unsigned-big-size(bits)>>

        {:ok, 200, %{"value" => b64url_encode(sig), "kid" => kid, "alg" => alg}}
      rescue
        _ in [ErlangError, ArgumentError] ->
          {:error, 400,
           bad_request("InvalidParameter",
             "digest size #{byte_size(digest)} bytes does not match #{alg} over #{ec_crv(record)}"
           )}
      end
    end
  end

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
         {:ok, alg} <- sign_alg(params),
         :ok <- alg_for_key_type(alg, {:rsa, key}) do
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

  # ECDSA verify: the wire signature is the raw JWS `r||s` form — re-assembled
  # to DER ECDSA-Sig-Value for :public_key.verify. A malformed/short signature
  # is a 200 with "value": false (KeyVerifyResult), never an error.
  defp do_verify(record, params, {:ec, curve, _priv_rec}) do
    kid = record["kid"]

    with {:ok, digest} <- sign_digest(params),
         {:ok, sig} <- verify_signature(params),
         {:ok, alg} <- sign_alg(params),
         :ok <- alg_for_key_type(alg, {:ec, curve, nil}) do
      bits = curve.coord * 8

      valid =
        try do
          <<r::unsigned-big-size(^bits), s::unsigned-big-size(^bits)>> = sig
          der_sig = ec_sig_der_encode(r, s)
          :crypto.verify(:ecdsa, curve.md, {:digest, digest}, der_sig, [
            ec_public_point(record, curve),
            curve.curve
          ]) == true
        rescue
          _ in [ErlangError, ArgumentError, MatchError] -> false
        end

      {:ok, 200, %{"value" => valid, "valid" => valid, "kid" => kid}}
    end
  end

  # The public point rides the private key's DER on the row; a missing row
  # (verify against a bare record without material) cannot verify.
  defp ec_public_point(record, curve) do
    coord = curve.coord

    with {:ok, der} <- stored_der(record),
         {:ECPrivateKey, _v, _priv, _params, pub_point, _attrs} <-
           :public_key.der_decode(:ECPrivateKey, der),
         <<4, _::unsigned-big-size(^coord * 16)>> <- pub_point do
      pub_point
    else
      _ -> <<>>
    end
  end

  # Minimal DER SEQUENCE{r INTEGER, s INTEGER} codec for ECDSA signatures —
  # :public_key.der_encode/decode does not carry :ECDSA_Sig_Value.
  defp ec_sig_der_decode(<<0x30, _len, 0x02, rlen::unsigned-big-size(8), r::binary-size(rlen),
                           0x02, slen::unsigned-big-size(8), s::binary-size(slen)>>) do
    {:binary.decode_unsigned(r), :binary.decode_unsigned(s)}
  end

  defp ec_sig_der_encode(r, s) do
    r_der = ec_integer_der(r)
    s_der = ec_integer_der(s)
    body = r_der <> s_der
    <<0x30, byte_size(body), body::binary>>
  end

  defp ec_integer_der(v) do
    raw = :binary.encode_unsigned(v)
    # INTEGER is signed: a leading 0x00 pads a high bit set.
    raw = if bit_size_head(raw) == 1, do: <<0, raw::binary>>, else: raw
    <<0x02, byte_size(raw), raw::binary>>
  end

  defp bit_size_head(<<first::unsigned-big-size(8), _::binary>>), do: div(first, 128)
  defp bit_size_head(<<>>), do: 0

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

  # EC keys cannot encrypt/wrap in the real contract (no EC encryption alg).
  defp encrypt_alg({:ec, _, _}, %{"alg" => _}),
    do: {:error, 400, unsupported_alg_for_key_type()}

  defp encrypt_alg({:oct, _}, %{"alg" => "RSA-OAEP-256"}),
    do: {:error, 400, unsupported_alg_for_key_type()}

  defp encrypt_alg({:rsa, _}, %{"alg" => "A256GCM"}),
    do: {:error, 400, unsupported_alg_for_key_type()}

  defp encrypt_alg(_, %{"alg" => other}),
    do: {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg #{other}")}

  defp encrypt_alg(_, _), do: {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}

  defp sign_alg(%{"alg" => alg}) when alg in ["RS256", "PS256", "ES256", "ES384"],
    do: {:ok, alg}

  defp sign_alg(%{"alg" => other}),
    do: {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg #{other}")}

  defp sign_alg(_), do: {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}

  # SHIM-COURT: alg/key-type compatibility is a typed 400 (real contract's
  # "algorithm not supported for this key type"), never a silent false verify.
  defp alg_for_key_type(alg, {:rsa, _}) when alg in ["RS256", "PS256"], do: :ok

  defp alg_for_key_type(alg, {:ec, curve, _}) when alg == curve.alg, do: :ok

  defp alg_for_key_type(_alg, _material), do: {:error, 400, unsupported_alg_for_key_type()}

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

  # ---------------------------------------------------------------------------
  # w6bc: KV key parity gaps (additive; landed rotation/backup clauses untouched)
  # ---------------------------------------------------------------------------

  @doc "POST /keys/:name/randomnumbers (w6bc): length random bytes wrapped by the key per alg. oct keys get AES-KW; RSA faces typed-UNSUPPORTED (400 InvalidAlgorithm)."
  def random_numbers(name, params) when is_map(params) do
    with_key(name, "wrapKey", params, nil, fn record, _params, material ->
      with {:ok, alg} <- randomnumbers_alg(material, params),
           {:ok, len} <- randomnumbers_length(params["length"]),
           {:ok, plain} <- kw_rand(material, alg, len) do
        case do_kw(material, alg, plain, record["kid"]) do
          {wrapped, kid} -> {:ok, 200, %{"value" => b64url_encode(wrapped), "kid" => kid}}
        end
      end
    end)
  end

  def random_numbers(_name, _params) do
    {:error, 400, bad_request("InvalidParameter", "request body must be a JSON object")}
  end

  defp kw_rand({:oct, _}, _alg, len), do: {:ok, :crypto.strong_rand_bytes(len)}

  defp do_kw({:oct, key}, _alg, plain, kid), do: {kw_wrap(key, plain), kid}

  defp randomnumbers_alg({:oct, key}, %{"alg" => "A256KW"}) when byte_size(key) == 32, do: {:ok, "A256KW"}
  defp randomnumbers_alg({:oct, key}, %{"alg" => "A192KW"}) when byte_size(key) == 24, do: {:ok, "A192KW"}
  defp randomnumbers_alg({:oct, _key}, %{"alg" => "A128KW"}), do: {:ok, "A128KW"}

  defp randomnumbers_alg({:oct, _}, %{"alg" => kw}) when kw in ["A256KW", "A192KW", "A128KW"] do
    {:error, 400, bad_request("InvalidAlgorithm", "oct key size does not match requested KW alg")}
  end

  defp randomnumbers_alg(_m, %{"alg" => "RSA-OAEP-256"}) do
    {:error, 400, bad_request("InvalidAlgorithm", "randomnumbers RSA faces are typed-UNSUPPORTED at this tier")}
  end

  defp randomnumbers_alg(_m, %{"alg" => other}) do
    {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg " <> other)}
  end

  defp randomnumbers_alg(_m, _params) do
    {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}
  end

  defp randomnumbers_length(len) when is_integer(len) and len in 16..128 and rem(len, 8) == 0, do: {:ok, len}

  defp randomnumbers_length(_) do
    {:error, 400, bad_request("InvalidParameter", "length must be an integer in 16..128 and a multiple of 8")}
  end

  @doc "AES Key Wrap dispatch for wrapKey/unwrapKey (w6bc): oct keys get RFC 3394/5649 AES-KW (A256KW/A192KW/A128KW); the landed A256GCM oct face is preserved; RSA keeps the landed RSA-OAEP-256 face. Additive."
  def key_wrap(name, params, version \\ nil)

  def key_wrap(name, params, version) do
    with_key(name, "wrapKey", params, version, fn record, params, material ->
      case material do
        {:oct, key} ->
          if kw_alg_request?(params) do
            with {:ok, alg} <- kw_alg(params, key),
                 {:ok, plain} <- b64_field(params, "value"),
                 :ok <- kw_multiple?(plain) do
              {:ok, 200, %{"value" => b64url_encode(kw_wrap(key, plain)), "kid" => record["kid"], "alg" => alg}}
            end
          else
            do_encrypt(record, params, {:oct, key})
          end

        {:rsa, _} = rsa ->
          do_encrypt(record, params, rsa)
      end
    end)
  end

  @doc "Public AES-KW seam (w6bc): RFC 3394 wrap/unwrap exposed for callers; asserted byte-exact against the RFC 3394 B.2 vector in the w6bc witness."
  def aes_kw_wrap(kek, plain), do: kw_wrap(kek, plain)
  def aes_kw_unwrap(kek, wrapped), do: kw_unwrap(kek, wrapped)

  @doc "AES-KW unwrap side of key_wrap/3."
  def key_unwrap(name, params, version \\ nil)

  def key_unwrap(name, params, version) do
    with_key(name, "unwrapKey", params, version, fn record, params, material ->
      case material do
        {:oct, key} ->
          if kw_alg_request?(params) do
            with {:ok, alg} <- kw_alg(params, key),
                 {:ok, wrapped} <- b64_field(params, "value"),
                 :ok <- kw_multiple?(wrapped) do
              {:ok, 200, %{"value" => b64url_encode(kw_unwrap(key, wrapped)), "kid" => record["kid"], "alg" => alg}}
            end
          else
            do_decrypt(record, params, {:oct, key})
          end

        {:rsa, _} = rsa ->
          do_decrypt(record, params, rsa)
      end
    end)
  end

  defp kw_alg_request?(%{"alg" => alg}) when alg in ["A256KW", "A192KW", "A128KW"], do: true
  defp kw_alg_request?(%{"alg" => _}), do: false
  defp kw_alg_request?(_), do: false

  defp kw_multiple?(bin) when rem(byte_size(bin), 8) == 0, do: :ok

  defp kw_multiple?(_) do
    {:error, 400, bad_request("InvalidValue", "AES-KW value must be a multiple of 8 bytes")}
  end

  defp kw_alg(%{"alg" => "A256KW"}, key) when byte_size(key) == 32, do: {:ok, "A256KW"}
  defp kw_alg(%{"alg" => "A192KW"}, key) when byte_size(key) == 24, do: {:ok, "A192KW"}
  defp kw_alg(%{"alg" => "A128KW"}, key) when byte_size(key) == 16, do: {:ok, "A128KW"}

  defp kw_alg(%{"alg" => kw}, _key) when kw in ["A256KW", "A192KW", "A128KW"] do
    {:error, 400, bad_request("InvalidAlgorithm", "oct key size does not match requested KW alg")}
  end

  defp kw_alg(%{"alg" => other}, _key) do
    {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg " <> other)}
  end

  defp kw_alg(_params, _key) do
    {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}
  end

  @doc "Versions listing with real pagination (w6bc): maxresults (1..25) + $skip. Landed list_versions/1 untouched."
  def list_versions_paged(name, opts) when is_list(opts) do
    maxresults = paging_int(opts[:maxresults], 25, 1, 25)
    skip = paging_int(opts[:skip], 0, 0, nil)

    case fetch(name) do
      {:ok, %{"versions" => versions} = record} when is_list(versions) and versions != [] ->
        items =
          versions
          |> Enum.drop(skip)
          |> Enum.take(maxresults)
          |> Enum.map(fn version ->
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

  def list_versions_paged(name, params) when is_map(params) do
    list_versions_paged(name,
      maxresults: paging_int(params["maxresults"], 25, 1, 25),
      skip: paging_int(params["$skip"], 0, 0, nil)
    )
  end

  def list_versions_paged(name, _), do: list_versions(name)

  defp paging_int(nil, default, _min, _max), do: default

  defp paging_int(v, _default, min, nil) when is_integer(v) and v >= min, do: v

  defp paging_int(v, _default, min, max) when is_integer(v) and v >= min and v <= max, do: v

  defp paging_int(_, default, _min, _max), do: default

  # ---------------------------------------------------------------------------
  # w6bc: AES-KW core (RFC 3394). OTP 28 :crypto has no :aes_kw cipher, so the
  # wrap/unwrap is the standard algorithm in pure Elixir (same approach as the
  # landed hand-built EMSA-PSS in kv_pss.ex). RFC 3394 B.2 vector asserted
  # byte-exact in the w6bc witness.
  # ---------------------------------------------------------------------------

  @kw_iv <<0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6>>

  defp kw_wrap(kek, plain) do
    n = div(byte_size(plain), 8)
    rs = for i <- 1..n, do: binary_part(plain, (i - 1) * 8, 8)
    [a | rest] = kw_loop(kek, @kw_iv, rs, n, 0)
    a <> Enum.join(rest)
  end

  defp kw_loop(_kek, a, rs, _n, 6), do: [a | rs]

  defp kw_loop(kek, a, rs, n, j) do
    {a2, rs2} =
      Enum.reduce(1..n, {a, rs}, fn i, {acc_a, acc_r} ->
        b = aes_block(kek, acc_a <> Enum.at(acc_r, i - 1))
        t = n * j + i
        <<msb::binary-size(8), lsb::binary-size(8)>> = b
        {kw_xor8(msb, t), List.replace_at(acc_r, i - 1, lsb)}
      end)

    kw_loop(kek, a2, rs2, n, j + 1)
  end

  defp kw_unwrap(kek, wrapped) do
    n = div(byte_size(wrapped) - 8, 8)
    <<a::binary-size(8), rest::binary>> = wrapped
    rs = for <<r::binary-size(8) <- rest>>, do: r
    [_a2 | rs2] = kw_unloop(kek, a, rs, n, 5)
    IO.iodata_to_binary(rs2)
  end

  defp kw_unloop(_kek, a, rs, _n, j) when j < 0, do: [a | rs]

  defp kw_unloop(kek, a, rs, n, j) do
    {a2, rs2} =
      Enum.reduce(n..1//-1, {a, rs}, fn i, {acc_a, acc_r} ->
        t = n * j + i
        xored = kw_xor8(acc_a, t)
        b = aes_block(kek, xored <> Enum.at(acc_r, i - 1), false)
        <<msb::binary-size(8), lsb::binary-size(8)>> = b
        {msb, List.replace_at(acc_r, i - 1, lsb)}
      end)

    kw_unloop(kek, a2, rs2, n, j - 1)
  end

  defp aes_block(kek, block, encrypt? \\ true) do
    cipher = :"aes_#{byte_size(kek) * 8}_ecb"
    :crypto.crypto_one_time(cipher, kek, block, encrypt?)
  end

  defp kw_xor8(<<a::integer-size(64)>>, t) do
    import Bitwise
    <<bxor(a, t)::integer-size(64)>>
  end
end
