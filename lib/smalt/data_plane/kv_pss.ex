defmodule Smalt.DataPlane.KvPss do
  @moduledoc """
  Externally verifiable RSA-PSS (PS256) signatures for the KV data plane.

  # KD-COVERS: KD-105

  Closes the KD-105/KD-119 family: the KV `PS256` path was internally
  self-consistent only — `key_vault_actions.ex` signs
  `:public_key.sign(digest, :sha256, key, rsa_padding: :rsa_pkcs1_pss_padding,
  rsa_pss_saltlen: 32)` and verifies with the in-process key, so external
  verifiers had no public material and no exported salt convention. This
  module is the external-verification seam:

    - `sign_pss/3`   — sign with RSA-PSS, salt length pinned to the digest
      size (32 for SHA-256), the RFC 8017 EMSA-PSS default JS/openssl
      verifiers expect (`rsa_pss_saltlen:32` / `saltLength: 32`).
    - `verify_pss/4` — verify against the public half (`{:RSAPublicKey, n, e}`
      reconstructed from the stored JWK `n`/`e`), fail-closed boolean.
    - `jwk_public/1` — export `kty`/`n`/`e`/`alg` so external verifiers
      (`openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt
      rsa_pss_saltlen:32`, or node `crypto.verify` with
      `padding: RSA_PKCS1_PSS_PADDING, saltLength: 32`) reproduce the verdict
      over the same digest.

  Digest convention matches the KV contract (`sign_digest/1` in
  `key_vault_actions.ex`): `sign_pss/3` / `verify_pss/4` take the message and
  hash it with SHA-256 internally (`:public_key` hashes under `:sha256`), so
  the wire's pre-hashed digest case is handled by callers hashing once — the
  module never double-hashes a caller-supplied DigestInfo.
  """

  @sha256_digest_size 32

  @doc """
  Sign a message with RSA-PSS (PS256).

  `private_der` is a DER-encoded `RSAPrivateKey`; `message` is hashed with
  SHA-256 internally. Salt length is deterministic (= 32, the digest size), so
  any RFC 8017 PSS verifier with saltlen=32 accepts. PSS is probabilistic —
  two signatures over the same message differ (random salt) and both verify.
  """
  @spec sign_pss(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def sign_pss(private_der, message, opts \\ []) when is_binary(private_der) and is_binary(message) do
    with {:ok, key} <- decode_private(private_der) do
      saltlen = Keyword.get(opts, :salt_len, @sha256_digest_size)

      {:ok,
       :public_key.sign(message, :sha256, key,
         rsa_padding: :rsa_pkcs1_pss_padding,
         rsa_pss_saltlen: saltlen,
         rsa_mgf1_md: :sha256
       )}
    end
  end

  @doc """
  Verify a PSS signature. Fail-closed boolean.

  `key_ref` is a DER-encoded `RSAPublicKey`, or `{n_b64url, e_b64url}` JWK
  fields (padding tolerated). Salt length defaults to 32 (digest size);
  a signature produced with a different salt length returns `false`, which is
  the deterministic-salt contract, not a limitation.
  """
  @spec verify_pss(binary() | {binary(), binary()}, binary(), binary(), keyword()) :: boolean()
  def verify_pss(key_ref, message, sig, opts \\ []) do
    saltlen = Keyword.get(opts, :salt_len, @sha256_digest_size)

    with {:ok, pub} <- public_key(key_ref) do
      try do
        :public_key.verify(message, :sha256, sig, pub,
          rsa_padding: :rsa_pkcs1_pss_padding,
          rsa_pss_saltlen: saltlen,
          rsa_mgf1_md: :sha256
        )
      rescue
        _ in [ErlangError, ArgumentError] -> false
      end
    end
  end

  @doc """
  Export the public half as JWK members `kty`/`n`/`e`/`alg`
  (base64url, unpadded). `private_der` is the DER private key backing the KV
  key record.
  """
  @spec jwk_public(binary()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def jwk_public(private_der) when is_binary(private_der) do
    with {:ok, key} <- decode_private(private_der) do
      n = elem(key, 2)
      e = elem(key, 3)

      {:ok,
       %{
         "kty" => "RSA",
         "n" => b64url_encode(:binary.encode_unsigned(n)),
         "e" => b64url_encode(:binary.encode_unsigned(e)),
         "alg" => "PS256"
       }}
    end
  end

  # -- internals ------------------------------------------------------------

  defp decode_private(der) do
    {:ok, :public_key.der_decode(:RSAPrivateKey, der)}
  rescue
    _ in [ErlangError, ArgumentError] -> {:error, :bad_private_der}
  end

  defp public_key({n_b64, e_b64}) when is_binary(n_b64) and is_binary(e_b64) do
    with {:ok, n} <- b64url_decode(n_b64),
         {:ok, e} <- b64url_decode(e_b64) do
      {:ok, {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}}
    end
  end

  defp public_key(der) when is_binary(der) do
    {:ok, :public_key.der_decode(:RSAPublicKey, der)}
  rescue
    _ in [ErlangError, ArgumentError] -> {:error, :bad_public_der}
  end

  defp public_key(_), do: {:error, :bad_key_ref}

  defp b64url_encode(bin), do: Base.url_encode64(bin, padding: false)

  defp b64url_decode(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64url}
    end
  end
end
