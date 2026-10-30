defmodule Smalt.Identity.OidcJwks do
  @moduledoc """
  JWKS face for the OIDC IdP: loads the dev RSA key pair
  (`.smalt/tls/dev-key.pem` / `dev-cert.pem` — same material the SAML IdP
  uses) and renders a single-key `keys` document (`kty RSA`, `n`, `e`, `kid`,
  `use sig`, `alg RS256`).

  `kid` is SHA-256 over the DER RSAPublicKey, base64url unpadded. Key
  material is loaded lazily and cached in `:persistent_term` (same law as
  `Smalt.Security.ReceiptSigner` and `Smalt.Identity.SamlIdp`).
  """

  @key_ref {__MODULE__, :key_material}

  @doc """
  Returns `{:ok, jwk}` — a single JWK map for the dev key — or
  `{:error, reason}` when the PEM files are missing/unreadable.
  """
  @spec jwk() :: %{optional(String.t()) => String.t()} | {:error, term}
  def jwk do
    case key_material() do
      {:ok, material} -> {:ok, material.jwk}
      error -> error
    end
  end

  @doc "Full JWKS document: `%{\"keys\" => [jwk]}`."
  @spec jwks() :: {:ok, map()} | {:error, term}
  def jwks do
    case jwk() do
      {:ok, jwk} -> {:ok, %{"keys" => [jwk]}}
      error -> error
    end
  end

  @doc """
  Signs the JWS compact serialization `signing_input` (RSA-SHA256) with the
  dev private key. Byte-shape mirrors `Smalt.Security.ReceiptSigner.sign/1`
  but carries `kid` in the header — ReceiptSigner's fixed header
  (`%{"alg" => "RS256", "typ" => "JWT"}`) has no `kid`, and a JWKS-verifying
  client needs it.
  """
  @spec sign(binary()) :: binary()
  def sign(signing_input) when is_binary(signing_input) do
    {:ok, material} = key_material()
    :public_key.sign(signing_input, :sha256, material.private)
  end

  @doc "base64url, no padding."
  @spec b64url(binary()) :: String.t()
  def b64url(binary), do: Base.url_encode64(binary, padding: false)

  ## Internals

  defp key_material do
    case :persistent_term.get(@key_ref, :missing) do
      :missing -> load_and_cache()
      material -> {:ok, material}
    end
  end

  defp load_and_cache do
    cert_path = Application.get_env(:smalt, :oidc_cert_path, ".smalt/tls/dev-cert.pem")
    key_path = Application.get_env(:smalt, :oidc_key_path, ".smalt/tls/dev-key.pem")

    with {:ok, cert_pem} <- File.read(cert_path),
         {:ok, key_pem} <- File.read(key_path),
         {:ok, private} <- decode_private_key(key_pem),
         {:ok, cert_der} <- first_cert_der(cert_pem),
         {:ok, jwk} <- jwk_from_private(private, cert_der) do
      material = %{private: private, jwk: jwk}
      :persistent_term.put(@key_ref, material)
      {:ok, material}
    end
  end

  defp decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPrivateKey, _v, n, e, _d, _p, _q, _dp, _dq, _qi, _other} = key
          when is_integer(n) and is_integer(e) ->
            {:ok, key}

          other ->
            # EC or wrapped key: not usable for RS256 here.
            {:error, {:unsupported_key, elem(other, 0)}}
        end

      [] ->
        {:error, :no_pem_entries}
    end
  rescue
    e -> {:error, {:key_decode_failed, Exception.message(e)}}
  end

  defp first_cert_der(pem) do
    entries = :public_key.pem_decode(pem)

    case Enum.find(entries, fn {type, _der, _not_encrypted} -> type == :Certificate end) do
      {_, der, _} ->
        _ = :public_key.pem_entry_decode({:Certificate, der, :not_encrypted})
        {:ok, der}

      nil ->
        {:error, :no_certificate}
    end
  rescue
    e -> {:error, {:cert_decode_failed, Exception.message(e)}}
  end

  # RSAPrivateKey record: version(1), modulus(2), publicExponent(3) — same
  # element positions ReceiptSigner.derive_public/1 relies on.
  defp jwk_from_private(private, cert_der) do
    n = elem(private, 2)
    e = elem(private, 3)

    rsa_pub_der = :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, n, e})
    kid = Base.url_encode64(:crypto.hash(:sha256, rsa_pub_der), padding: false)
    _unused = cert_der

    {:ok,
     %{
       "kty" => "RSA",
       "use" => "sig",
       "alg" => "RS256",
       "kid" => kid,
       "n" => b64url(int_to_bytes(n)),
       "e" => b64url(int_to_bytes(e))
     }}
  end

  defp int_to_bytes(int) when int > 0 do
    int
    |> :binary.encode_unsigned()
  end

  defp int_to_bytes(int) when int < 0 do
    int
    |> abs()
    |> :binary.encode_unsigned()
  end
end
