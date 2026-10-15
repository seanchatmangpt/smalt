defmodule Smalt.TLS do
  @moduledoc """
  Optional TLS for the Bandit egress (8443) and ARM (9443) listeners.

  Lets https-only clients (e.g. Cosmos .NET SDK patterns) run against the
  local substrate. Three modes, driven by config:

      config :smalt, :tls, :auto           # default: self-signed dev cert generated into tmp/
      config :smalt, :tls, false           # plaintext HTTP
      config :smalt, :tls_certfile, "..."  # explicit certs, used as-is when both files exist
      config :smalt, :tls_keyfile, "..."

  `ensure_dev_cert/0` generates an RSA 2048 self-signed certificate with
  CN=127.0.0.1 and SAN IP:127.0.0.1 + DNS:localhost into `tmp/` (gitignored),
  cached by cert mtime (an existing parseable cert is reused; delete
  `tmp/dev-cert.pem` to force regeneration). The key file is chmod 600.

  **Production users must supply their own certificates** via
  `:tls_certfile`/`:tls_keyfile` — the auto-generated cert is for local
  development only and is not trusted by any real client trust store.
  """

  # ASN.1 OTP records are plain tuples; we build them positionally.
  # OTPTBSCertificate: version, serialNumber, signature, issuer, validity,
  #   subject, subjectPublicKeyInfo, issuerUniqueID, subjectUniqueID, extensions
  # OTPCertificate: tbsCertificate, signatureAlgorithm, signatureValue
  # SubjectPublicKeyInfo: algorithm, subjectPublicKey
  # AlgorithmIdentifier: algorithm, parameters
  # Extension: extnID, critical, extnValue
  # Validity: notBefore, notAfter (each {:utcTime | :generalizedTime, charlist})

  @sha256_rsa_oid {1, 2, 840, 113549, 1, 1, 11}
  @rsa_enc_oid {1, 2, 840, 113549, 1, 1, 1}

  defp alg, do: {:"AlgorithmIdentifier", @sha256_rsa_oid, :asn1_NOVALUE}

  # SPKI must carry rsaEncryption (with NULL params), not a signature algorithm.
  defp spki_alg, do: {:"AlgorithmIdentifier", @rsa_enc_oid, <<0x05, 0x00>>}
  @cn_oid {2, 5, 4, 3}
  @san_oid {2, 5, 29, 17}
  @basic_constraints_oid {2, 5, 29, 19}

  @cert_path "tmp/dev-cert.pem"
  @key_path "tmp/dev-key.pem"

  @doc """
  Returns `{:ok, cert_path, key_path}` when TLS should be enabled, or
  `{:error, reason}` when disabled or cert setup fails.

  Resolution order:
    1. `:smalt, :tls_certfile` / `:tls_keyfile` set and both files exist -> use them.
    2. `:smalt, :tls == :auto` (the default) -> generate self-signed dev cert into tmp/.
    3. otherwise -> `{:error, :tls_disabled}`.
  """
  @spec ensure_dev_cert() :: {:ok, String.t(), String.t()} | {:error, term()}
  def ensure_dev_cert do
    cert = Application.get_env(:smalt, :tls_certfile)
    key = Application.get_env(:smalt, :tls_keyfile)

    if is_binary(cert) and is_binary(key) and File.regular?(cert) and File.regular?(key) do
      case validate_certfile_pair(cert, key) do
        :ok ->
          {:ok, cert, key}

        # Explicit certfiles are operator-provided: never overwrite them.
        # Fail closed with a typed reason so bandit_opts/2 raises a
        # domain-named ArgumentError at boot instead of an opaque
        # :pubkey_pem FunctionClauseError from inside :ssl (witnessed,
        # lens-6 cycle-2 probe).
        {:error, reason} ->
          {:error, {:corrupt_certfile, cert, reason}}
      end
    else
      case Application.get_env(:smalt, :tls, :auto) do
        :auto -> generate_if_stale()
        _ -> {:error, :tls_disabled}
      end
    end
  end

  @doc """
  `:https` when TLS is enabled and a cert is available, else `:http`.
  """
  @spec scheme() :: :https | :http
  def scheme do
    case ensure_dev_cert() do
      {:ok, _cert, _key} -> :https
      _ -> :http
    end
  end

  @doc """
  Bandit child opts for `plug_module` on `port`, with scheme and cert material
  applied per config. The coordinator wires these in `Smalt.Application`:

      {Bandit, Smalt.TLS.bandit_opts(Smalt.EgressRouter, 8443)}

  Returns `[plug:, port:, scheme: :http]` when TLS is disabled or cert setup
  fails, so callers never need a fallback branch.
  """
  @spec bandit_opts(module(), :inet.port_number()) :: keyword()
  def bandit_opts(plug_module, port) do
    base = [plug: plug_module, port: port]

    case ensure_dev_cert() do
      {:ok, cert, key} ->
        [scheme: :https, certfile: to_charlist(Path.expand(cert)),
         keyfile: to_charlist(Path.expand(key))] ++ base

      # Explicit plaintext opt-out is a typed configuration, not a failure.
      {:error, :tls_disabled} ->
        [scheme: :http] ++ base

      # TLS was requested (:auto) and cert setup failed — fail closed at boot
      # instead of silently serving plaintext where https was expected.
      {:error, reason} ->
        raise ArgumentError,
              "Smalt.TLS: :tls is :auto but dev-cert setup failed: #{inspect(reason)}"
    end
  end

  # -- dev cert generation ----------------------------------------------------

  defp generate_if_stale do
    cert = Path.expand(@cert_path)
    key = Path.expand(@key_path)

    if File.regular?(cert) and File.regular?(key) do
      case parse_cert(cert) do
        {:ok, _} -> {:ok, cert, key}
        {:error, reason} -> regenerate(cert, key, reason)
      end
    else
      regenerate(cert, key, :missing)
    end
  end

  defp regenerate(cert, key, _prior) do
    case write_dev_cert(cert, key) do
      :ok ->
        {:ok, cert, key}

      {:error, reason} ->
        # Keep serving from an existing parseable cert on transient generation
        # failure; only a missing/broken cert propagates the error.
        if match?({:ok, _}, parse_cert(cert)) do
          {:ok, cert, key}
        else
          {:error, reason}
        end
    end
  end

  # Explicit-certfile usability: the cert must parse as a Certificate (same
  # safe wrapper as the :auto path) and the key must decode as PEM with at
  # least one entry. Existence alone is not usability — a corrupt explicit
  # certfile otherwise surfaces only as an opaque crash inside :ssl at
  # listener start.
  defp validate_certfile_pair(cert, key) do
    with {:ok, _} <- parse_cert(cert),
         {:ok, [_ | _] = _entries} <- safe_key_pem(key) do
      :ok
    else
      {:error, :unparseable_cert} -> {:error, :unparseable_cert}
      _ -> {:error, :unparseable_key}
    end
  end

  defp safe_key_pem(key_path) do
    with {:ok, pem} <- File.read(key_path) do
      safe_pem_decode(pem)
    end
  end

  defp parse_cert(path) do
    with {:ok, pem} <- File.read(path),
         {:ok, entries} when is_list(entries) and entries != [] <- safe_pem_decode(pem),
         [{:"Certificate", der, :not_encrypted} | _] <-
           Enum.filter(entries, &match?({:"Certificate", _, :not_encrypted}, &1)),
         decoded when decoded != :error <- safe_decode(der) do
      {:ok, path}
    else
      _ -> {:error, :unparseable_cert}
    end
  end

  # :public_key.pem_decode/1 raises on structurally broken PEM (truncated
  # blocks, bad base64) and returns [] for PEM-free input; both are the
  # "cached dev cert is corrupt" case, which must regenerate, not crash.
  defp safe_pem_decode(pem) do
    {:ok, :public_key.pem_decode(pem)}
  rescue
    _ -> :error
  end

  defp safe_decode(der) do
    {:ok, :public_key.der_decode(:"Certificate", der)}
  rescue
    _ -> :error
  end

  @doc false
  def write_dev_cert(cert_path, key_path) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(cert_path))),
         {:ok, cert_pem, key_pem} <- generate_dev_cert_pem(),
         :ok <- File.write(cert_path, cert_pem),
         :ok <- File.write(key_path, key_pem),
         :ok <- File.chmod(key_path, 0o600) do
      :ok
    end
  end

  @doc """
  Generates the self-signed dev cert + RSA 2048 key as PEMs:
  `{:ok, cert_pem, key_pem}`. CN=127.0.0.1, SAN IP:127.0.0.1 + DNS:localhost,
  basicConstraints CA:TRUE so the file can double as its own trust anchor in
  local tests.
  """
  @spec generate_dev_cert_pem() :: {:ok, binary(), binary()} | {:error, term()}
  def generate_dev_cert_pem do
    with {:ok, tbs, key} <- build_tbs(),
         {:ok, cert_der} <- sign_tbs(tbs, key) do
      cert_pem = :public_key.pem_encode([{:Certificate, cert_der, :not_encrypted}])
      key_der = :public_key.der_encode(:RSAPrivateKey, key)
      key_pem = :public_key.pem_encode([{:RSAPrivateKey, key_der, :not_encrypted}])
      {:ok, IO.iodata_to_binary(cert_pem), IO.iodata_to_binary(key_pem)}
    end
  end

  defp build_tbs do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    pubkey = rsa_pub_from_priv(key)
    spki_der = :public_key.der_encode(:RSAPublicKey, pubkey)

    spki = {:"SubjectPublicKeyInfo", spki_alg(), spki_der}

    tbs =
      {:"OTPTBSCertificate", :v3, serial(), alg(), {:rdnSequence, name("127.0.0.1")},
       {:"Validity", {:utcTime, ~c'250101000000Z'}, {:utcTime, ~c'351231235959Z'}},
       {:rdnSequence, name("127.0.0.1")}, spki, :asn1_NOVALUE, :asn1_NOVALUE,
       [
         {:"Extension", @basic_constraints_oid, true, <<0x30, 0x03, 0x01, 0x01, 0xFF>>},
         {:"Extension", @san_oid, false, san_der()}
       ]}

    {:ok, tbs, key}
  end

  defp name(cn) do
    atv = {:"AttributeTypeAndValue", @cn_oid, {:printableString, String.to_charlist(cn)}}
    [[atv]]
  end

  # RSAPrivateKey record: tag, version, modulus, publicExponent, ...
  # RSAPublicKey record: tag, modulus, publicExponent
  defp rsa_pub_from_priv(key) do
    {:"RSAPublicKey", elem(key, 2), elem(key, 3)}
  end

  defp san_der do
    # SEQUENCE { dNSName "localhost", iPAddress 127.0.0.1 }
    dns = <<0x82, 9>> <> "localhost"
    ip = <<0x87, 4, 127, 0, 0, 1>>
    body = IO.iodata_to_binary([dns, ip])
    <<0x30, byte_size(body)>> <> body
  end

  defp serial do
    <<n::unsigned-big-integer-size(120)>> = :crypto.strong_rand_bytes(15)
    n
  end

  defp sign_tbs(tbs, key) do
    der = :public_key.der_encode(:"OTPTBSCertificate", tbs)
    signature = :public_key.sign(der, :sha256, key, [])

    cert = {:"OTPCertificate", tbs, alg(), signature}

    {:ok, :public_key.der_encode(:"OTPCertificate", cert)}
  rescue
    e -> {:error, e}
  end
end
