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
  hash it with SHA-256 internally (`:public_key` hashes under `:sha256`); the
  wire's pre-hashed digest case is served by the `:prehashed` opt (EMSA-PSS
  over the caller-supplied digest, raw RSA op) so a wire digest is signed
  exactly once — the module never double-hashes.
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
  def sign_pss(private_der, message_or_digest, opts \\ [])
      when is_binary(private_der) and is_binary(message_or_digest) do
    with {:ok, key} <- decode_private(private_der) do
      saltlen = Keyword.get(opts, :salt_len, @sha256_digest_size)

      if opts[:prehashed] do
        {:ok, sign_prehashed(key, message_or_digest, saltlen)}
      else
        {:ok,
         :public_key.sign(message_or_digest, :sha256, key,
           rsa_padding: :rsa_pkcs1_pss_padding,
           rsa_pss_saltlen: saltlen,
           rsa_mgf1_md: :sha256
         )}
      end
    end
  end

  # OTP's :public_key has no prehashed-PSS mode (`:none` + rsa_pss_padding
  # EXITs "Can't EVP_PKEY_sign") and on OTP 28 :crypto's legacy
  # public_encrypt/private_decrypt wrappers refuse :public_key key tuples
  # outright, so the RAW RSA op is :crypto.mod_pow (OpenSSL BN modexp) —
  # sig = em^d mod n, left-padded to the modulus byte length k.
  # Salt is random per signature; the 0xBC trailer and MGF1-SHA256 match what
  # openssl's `-sigopt rsa_pss_saltlen:32` expects.
  defp sign_prehashed(key, digest, salt_len) do
    n = elem(key, 2)
    d = elem(key, 4)
    k = byte_size(:binary.encode_unsigned(n))
    salt = :crypto.strong_rand_bytes(salt_len)
    em_bits = modulus_bits(n) - 1
    em = emsa_pss_encode(digest, salt, em_bits)
    left_pad_k(:crypto.mod_pow(em, d, n) |> :binary.decode_unsigned(), k)
  end

  defp left_pad_k(int, k) do
    bin = :binary.encode_unsigned(int)
    :binary.copy(<<0>>, k - byte_size(bin)) <> bin
  end

  # Bit length of a positive integer (MSB position), for emBits = modBits - 1.
  defp modulus_bits(n) do
    bin = :binary.encode_unsigned(n)
    <<first, _rest::binary>> = bin
    (byte_size(bin) - 1) * 8 + byte_bit_length(first, 7)
  end

  defp byte_bit_length(0, _pos), do: 0
  defp byte_bit_length(_b, 0), do: 1

  defp byte_bit_length(b, pos) do
    if Bitwise.band(b, Bitwise.bsl(1, pos)) != 0,
      do: pos + 1,
      else: byte_bit_length(b, pos - 1)
  end

  @doc """
  Verify a PSS signature. Fail-closed boolean.

  `key_ref` is a DER-encoded `RSAPublicKey`, or `{n_b64url, e_b64url}` JWK
  fields (padding tolerated). Salt length defaults to 32 (digest size);
  a signature produced with a different salt length returns `false`, which is
  the deterministic-salt contract, not a limitation.
  """
  @spec verify_pss(binary() | {binary(), binary()}, binary(), binary(), keyword()) :: boolean()
  def verify_pss(key_ref, message_or_digest, sig, opts \\ []) do
    saltlen = Keyword.get(opts, :salt_len, @sha256_digest_size)

    with {:ok, pub} <- public_key(key_ref) do
      if opts[:prehashed] do
        verify_prehashed(pub, message_or_digest, sig)
      else
        try do
          :public_key.verify(message_or_digest, :sha256, sig, pub,
            rsa_padding: :rsa_pkcs1_pss_padding,
            rsa_pss_saltlen: saltlen,
            rsa_mgf1_md: :sha256
          )
        rescue
          _ in [ErlangError, ArgumentError] -> false
        end
      end
    end
  end

  # EMSA-PSS-VERIFY: raw public op (sig^e mod n) recovers the encoded
  # message, then the encoding is rebuilt from the caller digest and
  # compared. Fail-closed.
  defp verify_prehashed({:RSAPublicKey, n, e}, digest, sig) do
    k = byte_size(:binary.encode_unsigned(n))

    try do
      em = left_pad_k(:crypto.mod_pow(sig, e, n) |> :binary.decode_unsigned(), k)
      emsa_pss_verify(digest, em)
    rescue
      _ in [ErlangError, ArgumentError] -> false
    end
  end

  defp verify_prehashed(_, _, _), do: false

  # -- EMSA-PSS (RFC 8017 §9.1) ----------------------------------------------

  # emBits = modBits - 1, emLen = ceil(emBits/8); hLen = sLen = 32 (SHA-256).
  defp emsa_pss_encode(digest, salt, em_bits) do
    m_hash = digest
    s_len = byte_size(salt)
    h_len = 32
    em_len = ceil(em_bits / 8)
    top_bits = em_len * 8 - em_bits

    m_prime = <<0::size(64), m_hash::binary, salt::binary>>
    h = :crypto.hash(:sha256, m_prime)

    db_len = em_len - h_len - 1
    ps_len = em_len - s_len - h_len - 2
    db = <<0::unit(8)-size(ps_len), 0x01, salt::binary>>

    masked_db = xor_bytes(db, mgf1(h, db_len))
    <<first, rest::binary>> = masked_db
    masked_db = <<Bitwise.band(first, mask_for(top_bits)), rest::binary>>

    <<masked_db::binary, h::binary, 0xBC>>
  end

  defp emsa_pss_verify(digest, em) do
    h_len = 32
    s_len = 32
    em_len = byte_size(em)
    db_len = em_len - h_len - 1
    ps_len = em_len - h_len - s_len - 2

    if em_len < h_len + s_len + 2 do
      false
    else
      <<masked_db::binary-size(db_len), h::binary-size(h_len), 0xBC>> = em

      <<0::unit(8)-size(ps_len), 0x01, salt::binary-size(s_len)>> =
        xor_bytes(masked_db, mgf1(h, db_len))

      :crypto.hash(:sha256, <<0::size(64), digest::binary, salt::binary>>) == h
    end
  rescue
    _ in [MatchError, ErlangError, ArgumentError] -> false
  end

  defp mask_for(1), do: 0x7F
  defp mask_for(2), do: 0x3F
  defp mask_for(3), do: 0x1F
  defp mask_for(4), do: 0x0F
  defp mask_for(5), do: 0x07
  defp mask_for(6), do: 0x03
  defp mask_for(7), do: 0x01
  defp mask_for(0), do: 0xFF

  defp xor_bytes(a, b) do
    :crypto.exor(a, b)
  end

  defp mgf1(seed, len) do
    mgf1(seed, len, 0, "")
  end

  defp mgf1(_seed, len, _counter, acc) when byte_size(acc) >= len do
    binary_part(acc, 0, len)
  end

  defp mgf1(seed, len, counter, acc) do
    mgf1(seed, len, counter + 1, acc <> :crypto.hash(:sha256, <<seed::binary, counter::32>>))
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
