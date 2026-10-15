defmodule Smalt.Security.ReceiptSigner do
  @moduledoc """
  RS256 (RSA-SHA256) detached-JWS signing and verification for ledger receipts
  and attestation tokens, via `:public_key`.

  The RSA key pair comes from `Application.get_env(:smalt, :receipt_signing_key)`
  (`%{private: pem, public: pem}`) when configured; otherwise a 2048-bit key is
  generated once per VM lifetime and cached in `:persistent_term`.

  Alg-confusion safe: tokens whose `alg` is not exactly `"RS256"` (HS256,
  `none`, ...) are rejected before any key material is touched.
  """

  @alg "RS256"
  @key_ref {__MODULE__, :keypair}

  @doc """
  Signs `claims` (a string-keyed map) as a JWS compact serialization:
  `base64url(header).base64url(payload).base64url(signature)`.
  """
  @spec sign(map()) :: String.t()
  def sign(claims) when is_map(claims) do
    {private_key, _public} = keypair()

    header = %{"alg" => @alg, "typ" => "JWT"}
    signing_input = b64url(Jason.encode!(header)) <> "." <> b64url(Jason.encode!(claims))

    signature =
      :public_key.sign(signing_input, :sha256, wrap_private(private_key))
      |> b64url()

    signing_input <> "." <> signature
  end

  @doc """
  Verifies a JWS compact token. Returns `{:ok, claims}` or `{:error, reason}`.

  Rejects non-RS256 `alg` headers, malformed tokens, bad signatures, and
  (in `verify_token/2`) expired claims.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, term}
  def verify(token) when is_binary(token) do
    with {:ok, header, claims, signing_input, sig_bytes} <- split(token),
         :ok <- check_alg(header),
         :ok <- check_typ(header),
         :ok <- check_signature(signing_input, sig_bytes) do
      {:ok, claims}
    end
  end

  def verify(_other), do: {:error, :invalid_token}

  @doc """
  Verifies a token and its `exp` claim (epoch seconds). Expired or missing-`exp`
  tokens are rejected with `{:error, :token_expired}` / `{:error, :invalid_claims}`.
  A present-but-future `nbf` claim is rejected with `{:error, :token_not_yet_valid}`
  (`nbf == now` is accepted; the claim is optional).
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term}
  def verify_token(token) do
    with {:ok, claims} <- verify(token),
         :ok <- check_exp(claims),
         :ok <- check_nbf(claims) do
      {:ok, claims}
    end
  end

  ## Internals

  defp split(token) do
    case String.split(token, ".", parts: 3) do
      [h, p, s] ->
        with {:ok, header_bin} <- un_b64url(h),
             {:ok, claims_bin} <- un_b64url(p),
             {:ok, header} <- decode_json(header_bin),
             {:ok, claims} <- decode_json(claims_bin),
             {:ok, sig_bytes} <- un_b64url(s) do
          {:ok, header, claims, h <> "." <> p, sig_bytes}
        end

      _ ->
        {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp check_alg(%{"alg" => @alg}), do: :ok
  defp check_alg(%{"alg" => other}) when is_binary(other), do: {:error, {:bad_alg, other}}
  defp check_alg(_), do: {:error, :bad_alg}

  # RFC 8725 §3.11 explicit typing (lens-3): when `typ` is present it must be
  # exactly "JWT". ReceiptSigner always emits typ "JWT"; a foreign envelope that
  # declares its own type (e.g. TrustProfile's "ctp-envelope-v1") is refused
  # STRUCTURALLY — before the key is touched — so cross-surface non-interop no
  # longer depends on the two surfaces holding different keypairs. Absent `typ`
  # stays admitted (RFC 7519: typ is optional; legacy tokens).
  defp check_typ(%{"typ" => "JWT"}), do: :ok
  defp check_typ(%{"typ" => other}) when is_binary(other), do: {:error, {:bad_typ, other}}
  defp check_typ(%{"typ" => other}), do: {:error, {:bad_typ, other}}
  defp check_typ(_), do: :ok

  defp check_signature(signing_input, sig_bytes) do
    {_private, public} = keypair()

    if :public_key.verify(signing_input, :sha256, sig_bytes, wrap_public(public)) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_exp(claims) when is_map(claims) do
    now = System.system_time(:second)

    case claims do
      %{"exp" => exp} when is_integer(exp) and exp >= now -> :ok
      %{"exp" => _} -> {:error, :token_expired}
      _ -> {:error, :invalid_claims}
    end
  end

  defp check_exp(_), do: {:error, :invalid_claims}

  # nbf (not-before) is optional; when present it must not be in the future.
  # Same integer/other split as exp: a non-integer nbf is uninterpretable and
  # refused rather than ignored.
  defp check_nbf(claims) when is_map(claims) do
    now = System.system_time(:second)

    case claims do
      %{"nbf" => nbf} when is_integer(nbf) and nbf <= now -> :ok
      %{"nbf" => _} -> {:error, :token_not_yet_valid}
      _ -> :ok
    end
  end

  defp check_nbf(_), do: {:error, :invalid_claims}

  defp keypair do
    case :persistent_term.get(@key_ref, :missing) do
      :missing -> generate_and_cache()
      pair -> pair
    end
  end

  defp generate_and_cache do
    # Persistent-term write is a global GC scan; serialize so only one writer pays it.
    global_key = {__MODULE__, :keygen_lock}

    :global.trans({global_key, node()}, fn ->
      case :persistent_term.get(@key_ref, :missing) do
        :missing ->
          pair =
            case Application.get_env(:smalt, :receipt_signing_key) do
              %{private: priv_pem, public: pub_pem} ->
                {pem_decode(priv_pem), pem_decode(pub_pem)}

              _ ->
                priv = :public_key.generate_key({:rsa, 2048, 65_537})
                {priv, derive_public(priv)}
            end

          :persistent_term.put(@key_ref, pair)
          pair

        pair ->
          pair
      end
    end)
  end

  defp derive_public(key) when is_tuple(key) and elem(key, 0) == :RSAPrivateKey do
    # RSAPrivateKey record: version(1), modulus(2), publicExponent(3), ...
    modulus = elem(key, 2)
    public_exponent = elem(key, 3)

    :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, modulus, public_exponent})
    |> then(&:public_key.der_decode(:RSAPublicKey, &1))
  end

  defp derive_public(%{modulus: modulus, publicExponent: public_exponent}) do
    :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, modulus, public_exponent})
    |> then(&:public_key.der_decode(:RSAPublicKey, &1))
  end

  defp wrap_private(key), do: key
  defp wrap_public(key), do: key

  defp pem_decode(pem) do
    pem
    |> :public_key.pem_decode()
    |> hd()
    |> :public_key.pem_entry_decode()
  end

  defp b64url(binary) do
    binary
    |> Base.url_encode64(padding: false)
  end

  defp un_b64url(string) do
    case Base.url_decode64(string, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  rescue
    _ -> {:error, :invalid_base64}
  end

  defp decode_json(string) do
    case Jason.decode(string) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end
end
