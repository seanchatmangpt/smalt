defmodule Smalt.DataPlane.KeyVaultActions do
  @moduledoc """
  Key Vault / Managed HSM data-plane facade — delegates to the T09 split
  faces (lane L11):

  - `Smalt.DataPlane.KeyVault.Keys` — key CRUD/crypto engine: encrypt,
    decrypt, sign, verify, wrap/unwrap, create, list/versions, rotation
    policy, rotate, soft delete/recover/purge, update properties,
    backup/restore, key material (RSA / oct / oct-HSM / EC).
  - `Smalt.DataPlane.KeyVault.Secrets` — secret PATCH + soft
    delete/get/list/recover/purge (KD-102/KD-184/KD-185).
  - `Smalt.DataPlane.KeyVault.HSM` — `randomnumbers`, AES Key Wrap
    (RFC 3394/5649) wrap/unwrap, public AES-KW seam.
  - `Smalt.DataPlane.KeyVault.Certificates` — the ONE canonical SMALT-KVB1
    backup envelope codec (shared keys/certificates envelope, KD-103).
  - `Smalt.DataPlane.KeyVault.Auth` — KD-15 challenge posture accessors
    (`api_version/0`, `challenge_mode/0`).

  Every public function of the pre-split module remains callable here with
  identical arity, defaults, guards-by-dispatch and return shapes, so route
  handlers in `EgressRouter`/`KvRoutes`, `mcp/router`, and the sibling
  `Smalt.DataPlane.Certificates` backup-codec seam
  (`backup_codec/0`) are unchanged. Wire behavior is byte-identical.
  """

  alias Smalt.DataPlane.KeyVault.Auth
  alias Smalt.DataPlane.KeyVault.Certificates
  alias Smalt.DataPlane.KeyVault.HSM
  alias Smalt.DataPlane.KeyVault.Keys
  alias Smalt.DataPlane.KeyVault.Secrets

  # ---------------------------------------------------------------------------
  # KD-15 challenge posture (Auth face)
  # ---------------------------------------------------------------------------

  @doc """
  The Key Vault data-plane API version served on `/:keys`+`/secrets` routes —
  `config :smalt, :keyvault, api_version: "7.4"`. Default "7.4" when the
  profile is not loaded (`:all` boot), so the default boot is byte-identical.
  """
  @spec api_version :: binary()
  defdelegate api_version(), to: Auth

  @doc """
  The Key Vault challenge posture — `config :smalt, :keyvault,
  challenge_mode: :strict_bearer`. See `Smalt.Auth.Bearer.kv_challenge_mode/0`
  (the single read surface the router consumes).
  """
  @spec challenge_mode :: :strict_bearer | atom()
  defdelegate challenge_mode(), to: Auth

  # ---------------------------------------------------------------------------
  # Keys face (crypto + CRUD)
  # ---------------------------------------------------------------------------

  @doc """
  `POST /keys/:name/encrypt`. Body `{"alg": ..., "value": base64}`. RSA keys
  use RSA-OAEP-256, oct keys use AES-256-GCM. Returns
  `{:ok, 200, %{"value" => ciphertext-b64, "kid" => kid}}`.
  """
  defdelegate encrypt(name, params, version \\ nil), to: Keys

  @doc "Inverse of `encrypt/2..3`; same tuple shape with plaintext-b64."
  defdelegate decrypt(name, params, version \\ nil), to: Keys

  @doc "Same mechanics as `encrypt/2` on the wrapKey route."
  defdelegate wrap_key(name, params, version \\ nil), to: Keys

  @doc "Same mechanics as `decrypt/2` on the unwrapKey route."
  defdelegate unwrap_key(name, params, version \\ nil), to: Keys

  @doc "RS256/PS256/ES256/ES384 sign; digest is pre-hashed per the real contract."
  defdelegate sign(name, params, version \\ nil), to: Keys

  @doc "KeyVerifyResult (`value` bool + `valid` compat alias); a bad signature is a 200, not an error."
  defdelegate verify(name, params, version \\ nil), to: Keys

  @doc "`GET /keys`. All key records in the `:smalt_vault_keys` table, key order."
  defdelegate list_keys(), to: Keys

  @doc "`GET /keys/:name/versions`. Every version of `name`, newest first."
  defdelegate list_versions(name), to: Keys

  @doc "Mints a new key record over the `:smalt_vault_keys` table (module-level create seam)."
  defdelegate create_key(name, params \\ %{}), to: Keys

  @doc "`GET /keys/{name}/rotationpolicy` (Azure parity)."
  defdelegate get_rotation_policy(name), to: Keys

  @doc "`PUT /keys/{name}/rotationpolicy` (Azure parity); typed 400 on malformed bodies."
  defdelegate set_rotation_policy(name, params), to: Keys

  @doc "`POST /keys/:name/rotate` — new version from the SAME policy; management-plane op."
  defdelegate rotate_key(name, params \\ nil), to: Keys

  @doc "`DELETE /keys/:name` (soft delete)."
  defdelegate delete_key(name), to: Keys

  @doc "`GET /deletedkeys/:name`."
  defdelegate get_deleted_key(name), to: Keys

  @doc "`GET /deletedkeys`."
  defdelegate list_deleted_keys(), to: Keys

  @doc "`POST /deletedkeys/:name/recover`."
  defdelegate recover_deleted_key(name), to: Keys

  @doc "`POST /deletedkeys/:name/purge`; 409 Conflict under purge protection."
  defdelegate purge_deleted_key(name), to: Keys

  @doc "PATCH key attributes/tags on a key or key version."
  defdelegate update_key_properties(name, params, version \\ nil), to: Keys

  @doc "`POST /keys/{name}/backup` — SMALT-KVB1 blob carrying root + version rows."
  defdelegate backup_key(name), to: Keys

  @doc "`POST /keys/{name}/restore`; typed MalformedBackupBlob / NameConflict refusals."
  defdelegate restore_key(blob, opts \\ []), to: Keys

  @doc false
  defdelegate ensure_deleted_table(), to: Keys

  @doc "JWK public half for an EC key record (`crv`/`x`/`y`)."
  defdelegate ec_jwk_public(record), to: Keys

  @doc "Deterministic derived AES-256 material for `oct` keys (length-prefixed per version)."
  defdelegate derive_oct_key(name, version \\ nil), to: Keys

  @doc "Versions listing with real pagination (w6bc): maxresults (1..25) + $skip."
  defdelegate list_versions_paged(name, opts), to: Keys

  # ---------------------------------------------------------------------------
  # Secrets face
  # ---------------------------------------------------------------------------

  @doc "PATCH secret attributes/tags; a stale version is a 404 SecretNotFound."
  defdelegate update_secret_properties(name, params, version \\ nil), to: Secrets

  @doc "`DELETE /secrets/:name` (soft delete, real Azure contract)."
  defdelegate delete_secret(name), to: Secrets

  @doc "`GET /deletedsecrets/:name`."
  defdelegate get_deleted_secret(name), to: Secrets

  @doc "`GET /deletedsecrets`."
  defdelegate list_deleted_secrets(), to: Secrets

  @doc "`POST /deletedsecrets/:name/recover`."
  defdelegate recover_deleted_secret(name), to: Secrets

  @doc "`POST /deletedsecrets/:name/purge`; 409 Conflict under purge protection."
  defdelegate purge_deleted_secret(name), to: Secrets

  # ---------------------------------------------------------------------------
  # HSM face
  # ---------------------------------------------------------------------------

  @doc "`POST /keys/:name/randomnumbers` (w6bc) — wrapped random bytes per alg."
  defdelegate random_numbers(name, params), to: HSM

  @doc "AES Key Wrap dispatch for wrapKey (w6bc); A256GCM oct face preserved."
  defdelegate key_wrap(name, params, version \\ nil), to: HSM

  @doc "AES-KW unwrap side of key_wrap/3."
  defdelegate key_unwrap(name, params, version \\ nil), to: HSM

  @doc "Public AES-KW seam (w6bc); RFC 3394 B.2 vector asserted in the w6bc witness."
  defdelegate aes_kw_wrap(kek, plain), to: HSM

  @doc "Public AES-KW unwrap seam."
  defdelegate aes_kw_unwrap(kek, wrapped), to: HSM

  # ---------------------------------------------------------------------------
  # Certificates face (shared SMALT-KVB1 envelope codec)
  # ---------------------------------------------------------------------------

  @doc false
  @spec kv_backup_encode(map()) :: binary()
  defdelegate kv_backup_encode(bundle), to: Certificates

  @doc false
  @spec kv_backup_decode(binary(), binary()) :: {:ok, map()} | {:error, 400, map()}
  defdelegate kv_backup_decode(blob, kind), to: Certificates
end
