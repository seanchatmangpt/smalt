defmodule Smalt.DataPlane.SKR do
  @moduledoc """
  Secure Key Release (SKR): derived, per-key, attestation-bound release for
  `POST /keys/:name/release` (extracted from the canned `EgressRouter` handler).

  Contract (fixes the s10 S10 finding "custody transfer is fake"):

  - **Per-key, attestation-bound material.** Released material is
    `HKDF-SHA256(ikm: master secret, salt: key name, info: "smalt-skr-release" <> policy-hash, len: 32)`,
    base64url-encoded (no padding; standard base64 accepted on input fields). Two different keys (or two different release policies)
    release different material; the same key + policy releases deterministic
    (replayable) material.

  - **Master secret.** `Application.get_env(:smalt, :kv_master_secret)`; when
    unset, a dev fallback secret is generated once per VM and cached in
    `:persistent_term` (documented dev mode — releases are only deterministic
    within one VM boot).

  - **keyMaterialVersion.** An incrementing per-key release counter
    (`Store.update_counter` over `:smalt_vault_keys`), so every release is
    individually observable.

  - **Single-use nonce (jti).** When the MAA token carries a jti
    (`x-ms-runtime.jti`), release is single-use: the jti is recorded in the
    Store `:smalt_attestation_baseline` table under `skr-jti:` prefixed keys;
    a replayed jti is refused with `403 TokenReplay`. Tokens without a jti are
    allowed (documented dev mode) — their replay is bounded by the existing
    RS256+exp verification.

  - **Attested recipient binding (dev-documented).** If the token claims carry
    a recipient JWK (`"skr_recipient_jwk"`, RSA kty), the released material is
    encrypted to that recipient with RSA-OAEP-256. Otherwise the material is
    returned as plain base64 (documented dev mode for the emulator surface).

  Errors: `404 KeyNotFound`, `400 KeyNotExportable`, `403 UnauthorizedAttestation`,
  `403 TokenReplay`, `400 InvalidParameter` (malformed recipient JWK).
  """

  alias Smalt.Security.Attestation
  alias Smalt.Store

  @compliance_status "azure-compliant-cvm"
  @release_info_prefix "smalt-skr-release"
  @jti_prefix "skr-jti:"
  @version_prefix "skr-version:"
  @recipient_claim "skr_recipient_jwk"

  @doc """
  `POST /keys/:name/release`. `conn` is inspected for the MAA bearer token
  (and, when `Application.get_env(:smalt, :skr_allow_legacy_header)` is set,
  the legacy `x-ms-compliance-status` header). Returns
  `{:ok, 200, body}` / `{:error, status, body}` tuples for the route handler.
  """
  @spec release(String.t(), Plug.Conn.t()) :: {:ok, 200, map()} | {:error, pos_integer(), map()}
  def release(name, conn) do
    with {:ok, key_record, policy} <- fetch_exportable(name),
         {:ok, claims} <- authorized?(conn) do
      release_material(name, key_record, policy, claims)
    end
  end

  # ---------------------------------------------------------------------------
  # Admission: exportable key + attested caller
  # ---------------------------------------------------------------------------

  defp fetch_exportable(name) do
    case Store.get(:smalt_vault_keys, name) do
      {:ok, %{"release_policy" => nil}} ->
        {:error, 400, key_not_exportable()}

      {:ok, %{"release_policy" => policy} = key_record} when not is_nil(policy) ->
        {:ok, key_record, policy}

      {:ok, _} ->
        {:error, 400, key_not_exportable()}

      :error ->
        {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}}
    end
  end

  # Same admission as the former EgressRouter handler: a real RS256 MAA token
  # via Authorization: Bearer verified through Attestation.verify_token; the
  # legacy raw header path is honored only behind :skr_allow_legacy_header.
  # Compliance status is read from BOTH the flat claim form smalt's MAA emits
  # (`x-ms-compliance-status` top-level) and the real nested MAA form where the
  # claims live inside the `x-ms-isolation-tee` object.
  defp authorized?(conn) do
    case bearer_token(conn) do
      {:ok, token} ->
        case Attestation.verify_token(token) do
          {:ok, claims} ->
            if compliance_status(claims) == @compliance_status do
              {:ok, claims}
            else
              {:error, 403, unauthorized()}
            end

          {:error, _} ->
            {:error, 403, unauthorized()}
        end

      :none ->
        legacy_allowed? =
          Application.get_env(:smalt, :skr_allow_legacy_header, false) and
            legacy_compliance_status(conn) == @compliance_status

        if legacy_allowed? do
          {:ok, %{}}
        else
          {:error, 403, unauthorized()}
        end
    end
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> :none
    end
  end

  defp compliance_status(claims) do
    claims["x-ms-compliance-status"] ||
      get_in(claims, ["x-ms-isolation-tee", "x-ms-compliance-status"])
  end

  defp legacy_compliance_status(conn) do
    conn |> Plug.Conn.get_req_header("x-ms-compliance-status") |> List.first()
  end

  # ---------------------------------------------------------------------------
  # Single-use nonce (jti)
  # ---------------------------------------------------------------------------

  # jti rides the MAA runtime claims; absent -> allowed (documented dev mode).
  defp check_single_use(claims) do
    jti = get_in(claims, ["x-ms-runtime", "jti"])

    if is_binary(jti) and jti != "" do
      consume_jti(jti)
    else
      :ok
    end
  end

  # Atomic first-writer-wins over the Store ETS (update_counter's
  # insert-with-default form). Key prefix keeps these rows disjoint from the
  # hex64 measurement baseline rows in the same table.
  defp consume_jti(jti) do
    case Store.update_counter(:smalt_attestation_baseline, @jti_prefix <> jti, 1) do
      1 -> :ok
      _ -> {:error, 403, token_replay()}
    end
  end

  # ---------------------------------------------------------------------------
  # Material derivation
  # ---------------------------------------------------------------------------

  # Material derivation + recipient wrap are pure: a malformed recipient JWK
  # fails BEFORE the commit point, so a failed release consumes neither the
  # single-use jti nonce nor a keyMaterialVersion (both burn only on the
  # success path, below).
  defp release_material(name, key_record, policy, claims) do
    policy_hash = :crypto.hash(:sha256, Jason.encode!(policy))
    material = hkdf_sha256(master_secret(), name, @release_info_prefix <> policy_hash, 32)
    kid = key_record["kid"]

    case wrap_to_recipient(claims, material) do
      {:ok, value, extra} ->
        commit_release(name, kid, policy_hash, value, extra, claims)

      {:error, status, body} ->
        {:error, status, body}
    end
  end

  # Commit point: jti first-writer-wins (403 TokenReplay under race), then the
  # per-key version counter. Both fire only after wrap has succeeded.
  defp commit_release(name, kid, policy_hash, value, extra, claims) do
    with :ok <- check_single_use(claims) do
      version = Store.update_counter(:smalt_vault_keys, @version_prefix <> name, 1)

      {:ok, 200,
       Map.merge(
         %{
           "value" => value,
           "kid" => kid,
           "keyMaterialVersion" => version,
           "policyHash" => Base.url_encode64(policy_hash, padding: false),
           "status" => "Released"
         },
         extra
       )}
    end
  end

  # HKDF (RFC 5869) extract + expand, SHA-256. Exposed (@doc false) so the
  # RFC 5869 test vectors can fence the primitive directly.
  @doc false
  def hkdf_sha256(ikm, salt, info, len) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    expand(prk, info, len, <<>>, 0, <<>>)
  end

  defp expand(_prk, _info, len, _t, _i, acc) when byte_size(acc) >= len do
    binary_part(acc, 0, len)
  end

  defp expand(prk, info, len, t, i, acc) do
    t = :crypto.mac(:hmac, :sha256, prk, t <> info <> <<i + 1>>)
    expand(prk, info, len, t, i + 1, acc <> t)
  end

  # Dev fallback: generated once per VM, cached in persistent_term. Configure
  # :kv_master_secret for releases that survive a restart.
  defp master_secret do
    case Application.get_env(:smalt, :kv_master_secret) do
      secret when is_binary(secret) and secret != "" ->
        :crypto.hash(:sha256, secret)

      _ ->
        case :persistent_term.get({__MODULE__, :master_secret}, :missing) do
          :missing ->
            secret = :crypto.strong_rand_bytes(32)
            :persistent_term.put({__MODULE__, :master_secret}, secret)
            secret

          secret ->
            secret
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Attested-recipient binding
  # ---------------------------------------------------------------------------

  # With a recipient JWK in the token claims, material is released encrypted to
  # the attested recipient (RSA-OAEP-256). Without one: plain base64url
  # (documented dev mode).
  defp wrap_to_recipient(claims, material) do
    case claims[@recipient_claim] do
      nil ->
        {:ok, b64url_encode(material), %{"transport" => "plain", "mode" => "dev"}}

      %{"kty" => kty} = jwk when kty in ["RSA", "RSA-HSM"] ->
        with {:ok, n} <- jwk_b64_field(jwk, "n"),
             {:ok, e} <- jwk_b64_field(jwk, "e") do
          public = {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}

          wrapped =
            :public_key.encrypt_public(material, public, [
              {:rsa_padding, :rsa_pkcs1_oaep_padding},
              {:rsa_oaep_md, :sha256}
            ])

          {:ok, b64url_encode(wrapped), %{"transport" => "RSA-OAEP-256", "mode" => "attested-recipient"}}
        end

      _ ->
        {:error, 400,
         %{
           "error" => %{
             "code" => "InvalidParameter",
             "message" => "recipient JWK in token claims must be an RSA JWK with kty/n/e"
           }
         }}
    end
  end

  defp jwk_b64_field(jwk, field) do
    case jwk[field] do
      value when is_binary(value) ->
        case b64_decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, 400, invalid_recipient_jwk()}
        end

      _ ->
        {:error, 400, invalid_recipient_jwk()}
    end
  end

  # base64url without padding (JWK form); standard base64 accepted for compat.
  defp b64_decode(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(value)
    end
  end

  defp b64url_encode(bin), do: Base.url_encode64(bin, padding: false)

  # ---------------------------------------------------------------------------
  # Error bodies
  # ---------------------------------------------------------------------------

  defp unauthorized do
    %{
      "error" => %{
        "code" => "UnauthorizedAttestation",
        "message" =>
          "Secure Key Release refused: target environment failed azure-compliant-cvm attestation validation."
      }
    }
  end

  defp token_replay do
    %{
      "error" => %{
        "code" => "TokenReplay",
        "message" =>
          "Secure Key Release refused: this attestation token's single-use nonce (jti) was already consumed."
      }
    }
  end

  defp key_not_exportable do
    %{
      "error" => %{
        "code" => "KeyNotExportable",
        "message" => "Key does not contain an exportable release policy."
      }
    }
  end

  defp invalid_recipient_jwk do
    %{
      "error" => %{
        "code" => "InvalidParameter",
        "message" => "recipient JWK in token claims is malformed"
      }
    }
  end
end
