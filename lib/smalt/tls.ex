defmodule Smalt.TLS do
  @moduledoc """
  Optional TLS for the Bandit egress (8443) and ARM (9443) listeners.

  Lets https-only clients (e.g. Cosmos .NET SDK patterns) run against the
  local substrate. Three modes, driven by config:

      config :smalt, :tls, :auto           # default: self-signed dev cert generated into tmp/
      config :smalt, :tls, false           # plaintext HTTP
      config :smalt, :tls_certfile, "..."  # explicit certs, used as-is when both exist
      config :smalt, :tls_keyfile, "..."

  TLS version pin (`config :smalt, :tls_versions`) — default
  `[:"tlsv1.3", :"tlsv1.2"]` (the IMPL-14F flip; evidence pack: the TLS13 trial
  receipt's 4 PASS wire legs, the non-reproducing R90/D52 shape, and the
  captured server-side ML-KEM witness `selected_group: :x25519mlkem768`; the
  real-Go-client residual stays typed-open via the GOLEG lane). Set
  `[:"tlsv1.2"]` to restore the conservative R90/D52 1.2-only pin. 1.3 rides
  OTP default ciphers per the trial receipt
  (`docs/jira/v26.10.21/receipts/tls13-unpin-trial.md`). Dual-cert
  (`:tls_certs_keys`) augments the 1.2 pin with ECDSA suites.

  `ensure_dev_cert/0` generates an RSA 2048 self-signed certificate with
  CN=127.0.0.1 and SAN IP:127.0.0.1 + DNS:localhost into a seat-local path
  under `tmp/dev-certs/` (gitignored), keyed by Bandit port (or OS pid) — see
  `dev_cert_paths/1`. Cached by cert mtime (an existing parseable cert is
  reused; delete the seat's `dev-cert-<key>.pem` to force regeneration).
  Writes are atomic (tmp + rename), and regeneration is serialized per seat,
  so a concurrent boot never reads a truncated or pair-skewed PEM. The key
  file is chmod 600.

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

  @sha256_rsa_oid {1, 2, 840, 113_549, 1, 1, 11}
  @rsa_enc_oid {1, 2, 840, 113_549, 1, 1, 1}
  # id-ecPublicKey — AR-SEC-02 dual-cert plane (SMALT_TLS_ECDSA=1 opt-in).
  @ec_pubkey_oid {1, 2, 840, 10045, 2, 1}

  defp alg, do: {:AlgorithmIdentifier, @sha256_rsa_oid, :asn1_NOVALUE}

  # SPKI must carry rsaEncryption (with NULL params), not a signature algorithm.
  defp spki_alg, do: {:AlgorithmIdentifier, @rsa_enc_oid, <<0x05, 0x00>>}
  @cn_oid {2, 5, 4, 3}
  @san_oid {2, 5, 29, 17}
  @basic_constraints_oid {2, 5, 29, 19}

  # TLS-261014-01: the dev cert is per-seat state, never a shared file. The
  # old fixed `tmp/dev-cert.pem` made every concurrent VM/lane on the checkout
  # read and rewrite one file — three witnessed cross-lane Bandit-start crashes
  # (truncated PEM read mid-rewrite). Paths are now keyed by Bandit port (or,
  # when no port is known, by OS pid) and written atomically (tmp + rename).
  @cert_dir "tmp/dev-certs"

  @doc """
  Per-seat dev cert/key paths for `port` (or the current OS pid when no port
  is known). Two concurrent VMs never share a cert file.
  """
  @spec dev_cert_paths(term()) :: {String.t(), String.t()}
  def dev_cert_paths(lane_key \\ default_lane_key()) do
    dir = Path.expand(@cert_dir)
    {Path.join(dir, "dev-cert-#{lane_key}.pem"), Path.join(dir, "dev-key-#{lane_key}.pem")}
  end

  defp default_lane_key do
    System.get_env("SMALT_TLS_LANE") || "pid-#{:os.getpid()}"
  end

  @doc """
  Returns `{:ok, cert_path, key_path}` when TLS should be enabled, or
  `{:error, reason}` when disabled or cert setup fails.

  Resolution order:
    1. `:smalt, :tls_certfile` / `:tls_keyfile` set and both files exist -> use them.
    2. `:smalt, :tls == :auto` (the default) -> generate self-signed dev cert
       into a port-keyed path under tmp/dev-certs/.
    3. otherwise -> `{:error, :tls_disabled}`.
  """
  @spec ensure_dev_cert() :: {:ok, String.t(), String.t()} | {:error, term()}
  @spec ensure_dev_cert(term()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def ensure_dev_cert(lane_key \\ nil) do
    # R90/D52: env-cert source (SMALT_TLS_CERTFILE/KEYFILE) is checked first,
    # so the ARM twin and any bandit_opts consumer share one resolution path
    # — with validate_certfile_pair applied, which the old application.ex
    # env branch skipped.
    with {cert, key} when is_binary(cert) and is_binary(key) <- env_cert_pair(),
         :ok <- validate_certfile_pair(cert, key) do
      {:ok, cert, key}
    else
      _ -> resolve_config_cert(lane_key)
    end
  end

  defp env_cert_pair do
    cert = System.get_env("SMALT_TLS_CERTFILE")
    key = System.get_env("SMALT_TLS_KEYFILE")

    if is_binary(cert) and is_binary(key) and File.regular?(cert) and File.regular?(key) do
      {cert, key}
    else
      :no_env_cert
    end
  end

  defp resolve_config_cert(lane_key) do
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
        :auto -> generate_if_stale(lane_key || default_lane_key())
        _ -> {:error, :tls_disabled}
      end
    end
  end

  @doc """
  `:https` when TLS is enabled and a cert is available, else `:http`.
  """
  @spec scheme() :: :https | :http
  def scheme(lane_key \\ nil) do
    case ensure_dev_cert(lane_key) do
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

    case ensure_dev_cert(port) do
      {:ok, cert, key} ->
        # R90/D52: TLS 1.2-only + cipher pin applied unconditionally on
        # every https path (SHIM-COURT subject: the pin must hold for dev
        # certs too, not just the env-cert branch). Recent Go clients
        # (azurerm/azidentity) offer X25519MLKEM768 key shares that the OTP
        # 28 ssl app rejects, killing the handshake before the cert is even
        # evaluated. Go falls back to TLS 1.2 + ECDHE-RSA happily.
        #
        # AR-SEC-02 (v26.10.21): when SMALT_TLS_ECDSA=1 (or
        # config :smalt, :tls_certs_keys, true) and a valid ECDSA pair is
        # present (SMALT_TLS_ECDSA_CERTFILE/KEYFILE, else .smalt/tls/ecdsa-*),
        # the listener binds BOTH pairs via ssl :certs_keys — modern clients
        # negotiating an ECDSA sigalg get the P-256 leaf, RSA-only legacy
        # clients still get the RSA leaf. Default (flag unset) is byte-for-byte
        # the old single-certfile behavior: the ECDSA branch is unreachable.
        # AR-SEC-01 (v26.10.21) + IMPL-14F flip: the version pin lives behind
        # the `config :smalt, :tls_versions` seam, DEFAULT
        # `[:"tlsv1.3", :"tlsv1.2"]` (evidence pack: tls13-unpin-trial.md — 4
        # wire legs PASS, R90/D52 MLKEM shape non-reproducing on this host,
        # server-side witness `selected_group: :x25519mlkem768`; real-Go-client
        # residual typed-open via the GOLEG lane). Config-revert escape:
        # `config :smalt, :tls_versions, [:"tlsv1.2"]` restores the R90/D52
        # 1.2-only pin + 2-cipher pin byte-for-byte. When 1.3 is enabled the
        # 1.2-only cipher pin is dropped for OTP default ciphers — the exact
        # shape the trial legs ran with.
        {_dual?, tls_opts, cert_material} =
          case certs_keys_material(cert, key) do
            # Bandit (pinned ~> 1.6) rejects :certs_keys as a top-level option
            # ("Unsupported key(s) in top level config: [:certs_keys]",
            # witnessed first boot of this lane); ThousandIsland's SSL
            # transport accepts it inside transport_options and forwards it
            # straight to :ssl.listen.
            {true, cks} ->
              {true, [certs_keys: cks] ++ transport_tls_opts(true), []}

            {false, :no_pair} ->
              {false, transport_tls_opts(false), single_cert_opts(cert, key)}
          end

        [scheme: :https] ++ cert_material ++ [thousand_island_options: [transport_options: tls_opts]] ++ h2_parity() ++ base

      # Explicit plaintext opt-out is a typed configuration, not a failure.
      {:error, :tls_disabled} ->
        [scheme: :http] ++ h2_parity() ++ base

      # TLS was requested (:auto) and cert setup failed — fail closed at boot
      # instead of silently serving plaintext where https was expected.
      {:error, reason} ->
        raise ArgumentError,
              "Smalt.TLS: :tls is :auto but dev-cert setup failed: #{inspect(reason)}"
    end
  end

  # KD-COVERS: KD-157 — Bandit's default h2 stream-reset rate limit
  # ({500, 10_000} RSTs per 10s) GOAWAYs (ENHANCE_YOUR_CALM) in-flight streams
  # when a concurrent client cancels response bodies in bursts (witnessed:
  # 128-wide ARM ramp, ~18% of requests transport-retried with
  # ERR_HTTP2_SESSION_ERROR; substrate.log
  # "Stream resets rate exceeded 500 resets in 10000ms"). Real front doors do
  # not reset in-flight legitimate streams over client cancels; the emulator
  # (loopback-only) raises the ceiling 100x — still a bounded, fail-closed
  # anti-DoS backstop, not a disable.
  defp h2_parity do
    [http_2_options: [max_reset_stream_rate: {50_000, 10_000}]]
  end

  # -- TLS-everywhere opt-in (P14) ---------------------------------------------

  # Real Azure is https-only on every plane; locally only the 9444 twin speaks
  # TLS by default. SMALT_TLS_ALL_PLANES=1 (or config :smalt, :tls_all_planes,
  # true) mounts an ADDITIONAL https listener on the data-plane surface (same
  # plug as the 9444 twin, port :egress_tls_port, default 8445) alongside the
  # plaintext 8443 listener. Additive: flag unset leaves the default boot
  # byte-for-byte unchanged (no extra child, no cert work, no port bind).
  @doc """
  TLS-everywhere gate: `SMALT_TLS_ALL_PLANES=1` (or
  `config :smalt, :tls_all_planes, true`) enables the additive data-plane
  https listener. Default (flag unset / app env nil) is false — default boot
  is byte-for-byte unchanged.
  """
  def all_planes? do
    System.get_env("SMALT_TLS_ALL_PLANES") in ["1", "true"] or
      Application.get_env(:smalt, :tls_all_planes) == true
  end

  @doc """
  Port for the additive data-plane https listener (`:egress_tls_port`,
  default 8445 — adjacent to plaintext 8443, disjoint from the 9444 twin).
  """
  def egress_tls_port, do: Application.get_env(:smalt, :egress_tls_port, 8445)

  # -- AR-SEC-02 dual-cert (RSA + ECDSA) opt-in --------------------------------

  defp rsa_ciphers do
    # APIMWIRE compile-freeze SLA unblock (disclosed): HEAD pinned these as
    # CHARLISTS (~c"..."); the atom form (~w(...)a) is rejected by OTP ssl
    # ({:options, {:ciphers, [:"ECDHE-RSA-..."]}}) and broke every bandit
    # listener boot on this machine (all lanes). Charlists restore the
    # default-path semantics of HEAD; the ECDSA opt-in branch is the owner
    # lane's to qualify.
    [
      ~c"ECDHE-RSA-AES256-GCM-SHA384",
      ~c"ECDHE-RSA-AES128-GCM-SHA256"
    ]
  end

  # Version pin seam. Default is TLS 1.3 + 1.2 fallback (IMPL-14F flip,
  # evidence: tls13-unpin-trial.md); `config :smalt, :tls_versions,
  # [:"tlsv1.2"]` restores the R90/D52 1.2-only pin. Dual-cert mode augments
  # the 1.2 pin with the ECDSA suites.
  defp transport_tls_opts(dual?) do
    versions = Application.get_env(:smalt, :tls_versions, [:"tlsv1.3", :"tlsv1.2"])

    if :"tlsv1.3" in versions do
      # IMPL-14 flip: prefer the x25519mlkem768 hybrid KEM on TLS 1.3 legs.
      # `supported_groups` is a preference list, not a restriction, for the
      # server; OTP < 29 ssl refuses the mlkem atom, so the preference rides
      # the same tlsv1.3 branch as the version flip (IMPL-14F) — the 1.2-only
      # escape hatch below restores the pre-mlkem shape byte-for-byte.
      [versions: versions, supported_groups: [:x25519mlkem768, :x25519, :secp256r1]]
    else
      ciphers = if dual?, do: ecdsa_ciphers() ++ rsa_ciphers(), else: rsa_ciphers()
      [versions: versions, ciphers: ciphers]
    end
  end

  defp single_cert_opts(cert, key) do
    [certfile: to_charlist(Path.expand(cert)), keyfile: to_charlist(Path.expand(key))]
  end

  defp ecdsa_ciphers do
    [
      ~c"ECDHE-ECDSA-AES256-GCM-SHA384",
      ~c"ECDHE-ECDSA-AES128-GCM-SHA256"
    ]
  end

  # Opt-in gate: env flag SMALT_TLS_ECDSA=1 (or config :smalt, :tls_certs_keys,
  # true). Anything else leaves the single-RSA-cert path untouched.
  defp certs_keys_material(rsa_cert, rsa_key) do
    ecdsa_on? =
      System.get_env("SMALT_TLS_ECDSA") in ["1", "true"] or
        Application.get_env(:smalt, :tls_certs_keys) == true

    with true <- ecdsa_on?,
         {ec_cert, ec_key} when is_binary(ec_cert) and is_binary(ec_key) <- ecdsa_pair(),
         :ok <- validate_certfile_pair(ec_cert, ec_key) do
      # Plug.SSL's certs_keys normalizer (Bandit runs Plug.SSL.configure) does
      # Map.to_list/1 on each entry — entries must be MAPS, not keyword lists
      # (witnessed: erl_stdlib_errors at maps.erl:1303 on first boot).
      {true,
       [
         %{certfile: to_charlist(Path.expand(ec_cert)), keyfile: to_charlist(Path.expand(ec_key))},
         %{certfile: to_charlist(Path.expand(rsa_cert)), keyfile: to_charlist(Path.expand(rsa_key))}
       ]}
    else
      _ -> {false, :no_pair}
    end
  end

  defp ecdsa_pair do
    cert = System.get_env("SMALT_TLS_ECDSA_CERTFILE") || Path.expand(".smalt/tls/ecdsa-cert.pem")
    key = System.get_env("SMALT_TLS_ECDSA_KEYFILE") || Path.expand(".smalt/tls/ecdsa-key.pem")

    if File.regular?(cert) and File.regular?(key), do: {cert, key}, else: :no_ecdsa_pair
  end

  # -- dev cert generation ----------------------------------------------------

  # TLS-261014-02: the boot-time read runs under the same :global lock the
  # writer publishes under. A concurrent regenerate can no longer be observed
  # half-applied (new cert + stale key) by a booting listener, and a corrupt
  # cached *key* — previously never checked on the :auto path, so it surfaced
  # as an opaque :ssl crash at Bandit start instead of regenerating — is now
  # detected and recovered. :global.trans is reentrant for the same process,
  # so the nested regenerate/3 call is safe.
  defp generate_if_stale(lane_key) do
    {cert, key} = dev_cert_paths(lane_key)

    :global.trans({__MODULE__, cert}, fn ->
      if File.regular?(cert) and File.regular?(key) do
        case parse_pair(cert, key) do
          :ok ->
            {:ok, cert, key}

          {:error, reason} ->
            regenerate(cert, key, reason)
        end
      else
        regenerate(cert, key, :missing)
      end
    end)
  end

  defp parse_pair(cert, key) do
    with {:ok, _} <- parse_cert(cert),
         {:ok, [_ | _]} <- safe_key_pem(key),
         :ok <- verify_pair(cert, key) do
      :ok
    else
      {:error, :unparseable_cert} -> {:error, :unparseable_cert}
      {:error, :cert_key_mismatch} -> {:error, :cert_key_mismatch}
      _ -> {:error, :unparseable_key}
    end
  end

  # TLS-261014-02 (R156 repair): the pair must actually match — a whole-but-
  # skewed pair (cert_n + key_n-1) parses cleanly and would otherwise be served
  # until the client fails the handshake. Pairing is an SPKI identity check:
  # the cert's SubjectPublicKeyInfo must equal the public half of the paired
  # private key. The previous pkix_verify(leaf, leaf_pubkey) only held for
  # self-signed certs and rejected every CA-chained leaf (e.g. the
  # gen_dev_cert.sh pair), silently deadening SMALT_TLS_CERTFILE.
  defp verify_pair(cert, key) do
    with {:ok, pem} <- File.read(cert),
         [{:Certificate, der, :not_encrypted} | _] <- :public_key.pem_decode(pem),
         {:ok, kpem} <- File.read(key),
         [key_entry | _] <- :public_key.pem_decode(kpem),
         :ok <- pair_check(der, key_entry) do
      :ok
    else
      _ -> {:error, :unparseable_key}
    end
  end

  # RSA leg — byte-identical semantics to the pre-AR-SEC-02 path.
  defp pair_check(cert_der, {key_type, _der, :not_encrypted} = key_entry)
       when key_type in [:RSAPrivateKey, :PrivateKeyInfo] do
    with {:ok, priv} <- rsa_key_der(key_entry) do
      key_pub = rsa_pub_from_priv(priv)

      if safe_spki_match(cert_der, key_pub) do
        :ok
      else
        {:error, :cert_key_mismatch}
      end
    end
  end

  # EC leg — SPKI identity check: the cert's subjectPublicKey (raw EC point)
  # must equal the key's embedded public point, on the same named curve.
  defp pair_check(cert_der, {:ECPrivateKey, key_der, :not_encrypted}) do
    with {:ok, ec_priv} <- safe_ec_decode(key_der),
         {:ok, spki} <- safe_cert_spki(cert_der) do
      if ec_spki_match(spki, ec_priv) do
        :ok
      else
        {:error, :cert_key_mismatch}
      end
    else
      _ -> {:error, :unparseable_key}
    end
  end

  defp pair_check(_cert_der, _other), do: {:error, :unparseable_key}

  defp safe_ec_decode(der) do
    {:ok, :public_key.der_decode(:ECPrivateKey, der)}
  rescue
    _ -> :error
  end

  defp safe_cert_spki(cert_der) do
    otp = :public_key.pkix_decode_cert(cert_der, :otp)
    {:ok, elem(elem(otp, 1), 7)}
  rescue
    _ -> :error
  end

  # OTP :otp-decode shape for an EC SPKI (witnessed by the first boot of this
  # lane — a badmatch on the assumed SubjectPublicKeyInfo shape):
  #   {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, id-ecPublicKey, {:namedCurve, curve}},
  #    {:ECPoint, point}}
  # The ECPrivateKey record carries the same curve in parameters (elem 3) and
  # the same raw point in publicKey (elem 4). Both must match.
  defp ec_spki_match(spki, ec_priv) do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @ec_pubkey_oid, {:namedCurve, curve}},
     {:ECPoint, point}} = spki

    elem(ec_priv, 3) == {:namedCurve, curve} and point == elem(ec_priv, 4)
  end

  # asn1 decoding can exit (NIF decode failure on a structurally broken cert)
  # — a cert whose SPKI cannot be extracted is, for boot purposes, a
  # mismatch/broken cert: regenerate or refuse, never crash.
  defp safe_spki_match(der, key_pub) do
    otp = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(otp, 1)
    spki = elem(tbs, 7)
    # subjectPublicKey in the OTP view is the decoded 'RSAPublicKey' record
    match?(^key_pub, elem(spki, 2))
  catch
    _, _ -> false
  end

  # Accept both traditional RSA ("RSA PRIVATE KEY") and PKCS#8 ("PRIVATE
  # KEY") PEM encodings — OpenSSL >= 3 mints PKCS#8 from -newkey -nodes.
  # Returns the decoded 'RSAPrivateKey' record either way.
  defp rsa_key_der({:RSAPrivateKey, der, :not_encrypted}) do
    {:ok, :public_key.der_decode(:RSAPrivateKey, der)}
  end

  defp rsa_key_der({:PrivateKeyInfo, der, :not_encrypted}) do
    # OTP decodes the inner OCTET STRING per privateKeyAlgorithm — the
    # result is already the 'RSAPrivateKey' record.
    {:ok, :public_key.der_decode(:PrivateKeyInfo, der)}
  end

  defp regenerate(cert, key, _prior) do
    # TLS-261014-01: serialize regenerates on the same lane key so two
    # concurrent callers can never interleave a cert from one generated pair
    # with the key from another. Rename is the CAS: last rename wins, and
    # every observer sees a whole, consistent file — no truncate window.
    :global.trans({__MODULE__, cert}, fn ->
      case write_dev_cert(cert, key) do
        :ok ->
          {:ok, cert, key}

        {:error, reason} ->
          # Keep serving from an existing parseable cert on transient
          # generation failure; only a missing/broken cert propagates.
          if match?({:ok, _}, parse_cert(cert)) do
            {:ok, cert, key}
          else
            {:error, reason}
          end
      end
    end)
  end

  # Explicit-certfile usability: the cert must parse as a Certificate (same
  # safe wrapper as the :auto path) and the key must decode as PEM with at
  # least one entry. Existence alone is not usability — a corrupt explicit
  # certfile otherwise surfaces only as an opaque crash inside :ssl at
  # listener start.
  defp validate_certfile_pair(cert, key) do
    with {:ok, _} <- parse_cert(cert),
         {:ok, [_ | _] = _entries} <- safe_key_pem(key),
         :ok <- verify_pair(cert, key) do
      :ok
    else
      {:error, :unparseable_cert} -> {:error, :unparseable_cert}
      {:error, :cert_key_mismatch} -> {:error, :cert_key_mismatch}
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
         [{:Certificate, der, :not_encrypted} | _] <-
           Enum.filter(entries, &match?({:Certificate, _, :not_encrypted}, &1)),
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
    {:ok, :public_key.der_decode(:Certificate, der)}
  rescue
    _ -> :error
  end

  @doc false
  def write_dev_cert(cert_path, key_path) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(cert_path))),
         {:ok, cert_pem, key_pem} <- generate_dev_cert_pem() do
      # Atomic publish: both PEMs fully written to temp files in the target
      # directory, then renamed into place. A concurrent reader on a
      # rename-ing filesystem always sees a whole file, never a truncation.
      tmp_cert = cert_path <> ".tmp-#{:erlang.unique_integer([:positive])}"
      tmp_key = key_path <> ".tmp-#{:erlang.unique_integer([:positive])}"

      try do
        with :ok <- File.write(tmp_cert, cert_pem),
             :ok <- File.write(tmp_key, key_pem),
             :ok <- File.chmod(tmp_key, 0o600),
             :ok <- File.rename(tmp_cert, cert_path),
             :ok <- File.rename(tmp_key, key_path) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(tmp_cert)
        File.rm(tmp_key)
      end
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

    spki = {:SubjectPublicKeyInfo, spki_alg(), spki_der}

    tbs =
      {:OTPTBSCertificate, :v3, serial(), alg(), {:rdnSequence, name("127.0.0.1")},
       {:Validity, {:utcTime, ~c'250101000000Z'}, {:utcTime, ~c'351231235959Z'}},
       {:rdnSequence, name("127.0.0.1")}, spki, :asn1_NOVALUE, :asn1_NOVALUE,
       [
         {:Extension, @basic_constraints_oid, true, <<0x30, 0x03, 0x01, 0x01, 0xFF>>},
         {:Extension, @san_oid, false, san_der()}
       ]}

    {:ok, tbs, key}
  end

  defp name(cn) do
    atv = {:AttributeTypeAndValue, @cn_oid, {:printableString, String.to_charlist(cn)}}
    [[atv]]
  end

  # RSAPrivateKey record: tag, version, modulus, publicExponent, ...
  # RSAPublicKey record: tag, modulus, publicExponent
  defp rsa_pub_from_priv(key) do
    {:RSAPublicKey, elem(key, 2), elem(key, 3)}
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
    der = :public_key.der_encode(:OTPTBSCertificate, tbs)
    signature = :public_key.sign(der, :sha256, key, [])

    cert = {:OTPCertificate, tbs, alg(), signature}

    {:ok, :public_key.der_encode(:OTPCertificate, cert)}
  rescue
    e -> {:error, e}
  end
end
