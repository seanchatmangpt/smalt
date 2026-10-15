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
  `400 {"error":{"code":"OperationNotAllowed"}}`.
  """

  alias Smalt.Store

  @default_ops ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]

  # ---------------------------------------------------------------------------
  # Encrypt / decrypt
  # ---------------------------------------------------------------------------

  @doc """
  `POST /keys/:name/encrypt`. Body `{"alg": ..., "value": base64}`. RSA keys
  use RSA-OAEP-256, oct keys use AES-256-GCM. Returns
  `{:ok, 200, %{"value" => ciphertext-b64, "kid" => kid}}`.
  """
  def encrypt(name, params), do: public_key_op(name, "encrypt", params, &do_encrypt/3)

  @doc """
  `POST /keys/:name/decrypt`. Inverse of `encrypt/2`. Returns
  `{:ok, 200, %{"value" => plaintext-b64, "kid" => kid}}`.
  """
  def decrypt(name, params), do: secret_key_op(name, "decrypt", params, &do_decrypt/3)

  @doc """
  `POST /keys/:name/wrapKey`. Same mechanics as `encrypt/2`.
  """
  def wrap_key(name, params), do: public_key_op(name, "wrapKey", params, &do_encrypt/3)

  @doc """
  `POST /keys/:name/unwrapKey`. Same mechanics as `decrypt/2`.
  """
  def unwrap_key(name, params), do: secret_key_op(name, "unwrapKey", params, &do_decrypt/3)

  # ---------------------------------------------------------------------------
  # Sign / verify
  # ---------------------------------------------------------------------------

  @doc """
  `POST /keys/:name/sign`. Body `{"alg": "RS256" | "PS256", "digest":
  base64url-of-SHA-256}` (real contract) or `"value": b64` pre-image (compat,
  digested server-side). Returns
  `{:ok, 200, %{"value" => signature-b64url, "kid" => kid}}`.
  """
  def sign(name, params), do: secret_key_op(name, "sign", params, &do_sign/3)

  @doc """
  `POST /keys/:name/verify`. Body `{"alg", "digest", "value": signature}`
  (real contract) or `"value": pre-image, "signature": sig` (compat). Returns
  `{:ok, 200, %{"value" => boolean, "kid" => kid}}` (KeyVerifyResult) with
  `"valid"` kept as a compat alias — a bad signature is a 200 with
  `"value": false`, not an error.
  """
  def verify(name, params), do: public_key_op(name, "verify", params, &do_verify/3)

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
           %{} = record -> [public_record(record)]
           _ -> []
         end)
     }}
  end

  @doc """
  `GET /keys/:name/versions`. Version listing for `name`. Version history is
  owned by the create route in `EgressRouter` (one row per key name today), so
  this reports the single current version; it is the seam to extend when
  create becomes versioned. Unknown key -> 404 KeyNotFound.
  """
  def list_versions(name) do
    case fetch(name) do
      {:ok, record} -> {:ok, 200, %{"value" => [public_record(record)]}}
      :error -> {:error, 404, key_not_found()}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch plumbing
  # ---------------------------------------------------------------------------

  defp public_key_op(name, op, params, fun) do
    with_key(name, op, params, fun)
  end

  # Secret-key ops (decrypt/sign) need the private material; verify only needs
  # the public half but shares the same admission path.
  defp secret_key_op(name, op, params, fun) do
    with_key(name, op, params, fun)
  end

  defp with_key(name, op, params, fun) when is_map(params) do
    case fetch(name) do
      {:ok, record} ->
        with :ok <- check_allowed(record, op),
             {:ok, material} <- key_material(name, record) do
          fun.(record, params, material)
        end

      :error ->
        {:error, 404, key_not_found()}
    end
  end

  defp with_key(_name, _op, _params, _fun) do
    {:error, 400, bad_request("InvalidParameter", "request body must be a JSON object")}
  end

  defp fetch(name) do
    case Store.get(:smalt_vault_keys, name) do
      {:ok, record} -> {:ok, record}
      :error -> :error
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
      {:error, 400,
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
    case policy["allowed_operations"] || policy["allowedOperations"] do
      ops when is_list(ops) and ops != [] -> Enum.map(ops, &to_string/1)
      _ -> @default_ops
    end
  end
  defp allowed_operations(_), do: @default_ops

  # ---------------------------------------------------------------------------
  # Key material
  # ---------------------------------------------------------------------------

  defp key_material(name, record) do
    case kty(record) do
      kty when kty in ["RSA", "RSA-HSM"] -> ensure_rsa(name, record)
      kty when kty in ["oct", "oct-HSM"] -> {:ok, {:oct, derive_oct(name)}}
      other -> {:error, 400, bad_request("UnsupportedKeyType", "kty #{other} is not supported")}
    end
  end

  defp kty(record), do: get_in(record, ["key", "kty"]) || "RSA-HSM"

  # Deterministic per key name at first use: generated once, DER cached in the
  # Store row under "key_material", reused for the life of the row.
  defp ensure_rsa(name, record) do
    case record["key_material"] do
      der when is_binary(der) ->
        {:ok, {:rsa, :public_key.der_decode(:RSAPrivateKey, der)}}

      _ ->
        key = :public_key.generate_key({:rsa, 2048, 65537})
        der = :public_key.der_encode(:RSAPrivateKey, key)
        Store.put(:smalt_vault_keys, name, Map.put(record, "key_material", der))
        {:ok, {:rsa, key}}
    end
  end

  defp derive_oct(name), do: derive_oct_key(name)

  @doc """
  Deterministic derived AES-256 material for `oct`/`oct-HSM` keys:
  `SHA-256("smalt-vault-derived:" <> name)`. Public so the create route can
  project the JWK `k` field (disclosed dev-material derivation).
  """
  def derive_oct_key(name), do: :crypto.hash(:sha256, "smalt-vault-derived:" <> name)

  defp rsa_public({:rsa, key}), do: {:RSAPublicKey, elem(key, 2), elem(key, 3)}

  # ---------------------------------------------------------------------------
  # Crypto implementations
  # ---------------------------------------------------------------------------

  defp do_encrypt(record, params, material) do
    kid = record["kid"]

    with {:ok, plain} <- b64_field(params, "value"),
         {:ok, alg} <- encrypt_alg(material, params) do
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

      {:ok, 200, Map.merge(%{"value" => b64url_encode(cipher), "kid" => kid, "alg" => alg}, extra)}
    end
  end

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
  # Compat: a client sending `value` (base64/base64url pre-image) is digested
  # server-side. `digest` wins when both are present.
  defp sign_digest(params) do
    case params["digest"] do
      d when is_binary(d) ->
        case b64_decode(d) do
          {:ok, digest} -> {:ok, digest}
          :error -> {:error, 400, bad_request("InvalidValue", "digest is not valid base64/base64url")}
        end

      _ ->
        case b64_field(params, "value") do
          {:ok, plain} -> {:ok, :crypto.hash(:sha256, plain)}
          error -> error
        end
    end
  end

  defp do_sign(record, params, {:rsa, key}) do
    kid = record["kid"]

    with {:ok, digest} <- sign_digest(params),
         {:ok, alg} <- sign_alg(params) do

      sig =
        case alg do
          "RS256" -> :public_key.sign(digest, :sha256, key, rsa_padding: :rsa_pkcs1_padding)
          "PS256" -> :public_key.sign(digest, :sha256, key, rsa_padding: :rsa_pkcs1_pss_padding, rsa_pss_saltlen: 32)
        end

      {:ok, 200, %{"value" => b64url_encode(sig), "kid" => kid, "alg" => alg}}
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
              "RS256" ->
                :public_key.verify(digest, :sha256, sig, rsa_public({:rsa, key}), rsa_padding: :rsa_pkcs1_padding)

              "PS256" ->
                :public_key.verify(digest, :sha256, sig, rsa_public({:rsa, key}),
                  rsa_padding: :rsa_pkcs1_pss_padding,
                  rsa_pss_saltlen: 32
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
  defp encrypt_alg({:oct, _}, %{"alg" => "RSA-OAEP-256"}), do: {:error, 400, unsupported_alg_for_key_type()}
  defp encrypt_alg({:rsa, _}, %{"alg" => "A256GCM"}), do: {:error, 400, unsupported_alg_for_key_type()}
  defp encrypt_alg(_, %{"alg" => other}), do: {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg #{other}")}
  defp encrypt_alg(_, _), do: {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}

  defp sign_alg(%{"alg" => alg}) when alg in ["RS256", "PS256"], do: {:ok, alg}
  defp sign_alg(%{"alg" => other}), do: {:error, 400, bad_request("InvalidAlgorithm", "unsupported alg #{other}")}
  defp sign_alg(_), do: {:error, 400, bad_request("InvalidAlgorithm", "alg is required")}

  defp unsupported_alg_for_key_type do
    bad_request("InvalidAlgorithm", "algorithm not supported for this key type")
  end

  # Wire encoding is base64url without padding (real KV contract). Input
  # compat: standard base64 (padded, +/) is also accepted on decode.
  defp b64url_encode(bin), do: Base.url_encode64(bin, padding: false)

  defp b64_decode(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(value)
    end
  end

  defp b64_field(params, field, opts \\ []) do
    case params[field] || opts[:default] do
      value when is_binary(value) ->
        case b64_decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, 400, bad_request("InvalidValue", "#{field} is not valid base64/base64url")}
        end

      _ ->
        {:error, 400, bad_request("InvalidParameter", "#{field} is required")}
    end
  end

  defp b64_field_value(value, field) do
    case b64_decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, 400, bad_request("InvalidValue", "#{field} is not valid base64/base64url")}
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
  # the vault — listings project the public record only.
  defp public_record(record) do
    Map.drop(record, ["key_material"])
  end
end
