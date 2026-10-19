defmodule Smalt.Auth.StsKey do
  # KD-COVERS: KD-99,KD-100 (RS256 mint + JWKS + instance-discovery envelope;
  # flip-gated on the identity-SDK witness receipt, scripts/kd_flip.py law)
  @moduledoc """
  STS signing-key authority (Portable Azure Target Law): the emulator STS is
  RS256-first. Official identity SDKs (@azure/identity
  ClientSecretCredential / msal-node) require RS256 mint + a published JWKS +
  the msal instance-discovery envelope; the legacy HS256 dev mode stays
  available as an explicit config opt-out (`config :smalt, :sts_key_mode,
  :hs256_dev`).

  Key resolution (once per VM, under `:global` lock, cached in
  `:persistent_term` WITH its mode stamped — a mid-VM
  `Application.put_env(:smalt, :sts_key_mode, ...)` flip is a no-op until
  restart):

  1. config/env `:smalt, :sts_signing_pem` → `JOSE.JWK.from_pem/1`. A malformed
     PEM raises `ArgumentError` (fail-closed: a silently-ignored key-material
     mistake would mint tokens nobody can pin).
  2. else if `config :smalt, :prod` → raise (never a random key in prod).
  3. else generate `{4096, :rsa}` once per VM and cache.

  `mode/0`:
  - `:rs256` (default) — RSA signing via `signer/0`; `jwk_map/0` serves the
    JWKS; `kid/0` is the RFC 7638 thumbprint (base64url, unpadded).
  - `:hs256_dev` — legacy HS256 path, wire byte-identical to the pre-StsKey
    dev behavior: shared secret from `:sts_signing_secret` (>= 32 bytes when
    set) or the generated dev secret.
  """

  @lock {__MODULE__, :lock}
  @cache {__MODULE__, :key_state}

  @type mode :: :rs256 | :hs256_dev

  @doc "STS key mode, stamped into the VM-lifetime cache at first touch."
  @spec mode() :: mode()
  def mode do
    {mode, _jwk, _signer, _kid, _hs} = state()
    mode
  end

  @doc """
  Joken signer for STS mint/verify. Cross-mode refuse: the returned signer's
  alg always equals `mode/0` — under `:rs256` it is the RSA signer, under
  `:hs256_dev` it is the legacy HS256 signer — and every accept branch in
  `Smalt.Auth.Bearer` is mode-gated, so an HS256-mode VM never admits an
  RS256 token and vice versa.
  """
  @spec signer() :: Joken.Signer.t()
  def signer do
    case state() do
      {:rs256, _jwk, signer, _kid, _hs} -> signer
      # cross-mode refuse: signer/0 never returns an alg ≠ mode — under
      # :hs256_dev the RS256 slots are nil and the HS256 signer is served.
      {:hs256_dev, _jwk, _signer, _kid, _hs} -> hs_signer()
    end
  end

  @doc """
  Public JWK map for the JWKS endpoint under `:rs256` (kty/n/e/use/alg/kid).
  nil under `:hs256_dev` (a shared secret is never published).
  """
  @spec jwk_map() :: map() | nil
  def jwk_map do
    case state() do
      {:rs256, jwk, _signer, kid, _hs} ->
        # JOSE.JWK.to_map/1 returns {%{:kty => :rsa} metadata, params-map with
        # BINARY keys (kty/n/e + private members)} — publish only kty/n/e.
        {_meta, params} = JOSE.JWK.to_map(jwk)

        %{
          "kty" => params["kty"],
          "n" => params["n"],
          "e" => params["e"],
          "use" => "sig",
          "alg" => "RS256",
          "kid" => kid
        }

      {:hs256_dev, _jwk, _signer, _kid, _hs} ->
        nil
    end
  end

  @doc "RFC 7638 thumbprint of the public key (base64url, unpadded)."
  @spec kid() :: String.t()
  def kid do
    {_mode, _jwk, _signer, kid, _hs} = state()
    kid
  end

  @doc """
  Legacy HS256 verify/mint signer (moved here from
  `Smalt.ArmGateway.Router.sts_signer/0` + `Smalt.Auth.Bearer.signer/0`):
  env `:smalt, :sts_signing_secret` (>= 32 bytes when set) wins, else the
  generated dev secret cached in `:persistent_term` under the SAME
  `{Smalt.ArmGateway.Router, :sts_signing_secret}` key the pre-StsKey code
  cached under — no cache migration, dev-secret identity preserved.
  """
  @spec hs_signer() :: Joken.Signer.t()
  def hs_signer do
    case Application.get_env(:smalt, :sts_signing_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        Joken.Signer.create("HS256", secret)

      other when is_binary(other) ->
        raise ArgumentError,
              "smalt :sts_signing_secret must be >= 32 bytes when set (got #{byte_size(other)})"

      _ ->
        case :persistent_term.get({Smalt.ArmGateway.Router, :sts_signing_secret}, :missing) do
          :missing -> generate_and_cache_dev_secret()
          secret -> Joken.Signer.create("HS256", secret)
        end
    end
  end

  @doc """
  True when the legacy HS256 path has key material available WITHOUT minting a
  new dev secret (env `:sts_signing_secret` set, or a dev secret already
  cached). The verify side uses this to preserve the pre-StsKey refusal
  (`NoSigningSecretConfigured`) when nothing was ever generated; the mint side
  may still generate lazily via `hs_signer/0`.
  """
  @spec hs_secret_available?() :: boolean()
  def hs_secret_available? do
    is_binary(Application.get_env(:smalt, :sts_signing_secret)) or
      :persistent_term.get({Smalt.ArmGateway.Router, :sts_signing_secret}, :missing) !=
        :missing
  end

  @doc """
  Mints a signed JWT for `claims` with the mode's key. Under `:rs256` the
  signing goes through JOSE directly (Joken's `JWS.compact/1` strips custom
  JWS header members — the JWK-thumbprint `kid` does not survive it), emitting
  `{"typ":"JWT","alg":"RS256","kid":<thumbprint>}`. Under `:hs256_dev` it is
  the legacy Joken path (`%{}` headers — wire byte-identical to pre-StsKey).
  """
  @spec mint(map()) :: {:ok, String.t()}
  def mint(claims) do
    case state() do
      {:rs256, jwk, _signer, kid, _hs} ->
        {_meta, compact} =
          jwk
          |> JOSE.JWS.sign(Jason.encode!(claims), %{"typ" => "JWT", "alg" => "RS256", "kid" => kid})
          |> JOSE.JWS.compact()

        {:ok, compact}

      {:hs256_dev, _jwk, _signer, _kid, _hs} ->
        {:ok, token, _} = Joken.generate_and_sign(%{}, claims, hs_signer())
        {:ok, token}
    end
  end

  # -- state -------------------------------------------------------------------

  # Cached tuple: {mode, jwk, signer, kid, hs_hint}. `hs_hint` is unused under
  # :rs256 (kept so the tuple shape is mode-independent).
  defp state do
    case :persistent_term.get(@cache, :missing) do
      :missing -> init_state()
      st -> st
    end
  end

  defp init_state do
    :global.trans({@lock, node()}, fn ->
      case :persistent_term.get(@cache, :missing) do
        :missing ->
          mode = config_mode()
          st = build_state(mode)
          :persistent_term.put(@cache, st)
          st

        st ->
          st
      end
    end)
  end

  defp config_mode do
    case Application.get_env(:smalt, :sts_key_mode, :rs256) do
      :hs256_dev -> :hs256_dev
      :rs256 -> :rs256
      other -> raise ArgumentError, "smalt :sts_key_mode must be :rs256 or :hs256_dev (got #{inspect(other)})"
    end
  end

  defp build_state(:rs256) do
    jwk = resolve_rs256_jwk()
    signer = Joken.Signer.create("RS256", jwk)
    kid = thumbprint(jwk)
    {:rs256, jwk, signer, kid, nil}
  end

  defp build_state(:hs256_dev) do
    # The HS256 dev secret is generated/cached lazily by hs_signer/0 under the
    # legacy Router key; the :rs256 slots are nil placeholders.
    {:hs256_dev, nil, nil, nil, nil}
  end

  # Env-PEM-first precedence, fail-closed on malformed PEM.
  defp resolve_rs256_jwk do
    case Application.get_env(:smalt, :sts_signing_pem) do
      pem when is_binary(pem) ->
        case JOSE.JWK.from_pem(pem) do
          %JOSE.JWK{} = jwk -> jwk
          _ -> raise ArgumentError, "smalt :sts_signing_pem is not a valid PEM"
        end

      _ ->
        if Application.get_env(:smalt, :prod, false) do
          raise ArgumentError,
                "smalt :sts_signing_pem must be configured in prod (Application.get_env(:smalt, :sts_signing_pem))"
        end

        JOSE.JWK.generate_key({:rsa, 4096})
    end
  end

  # RFC 7638: canonical JSON over the REQUIRED RSA members (e, kty, n —
  # lexicographic), SHA-256, base64url unpadded.
  defp thumbprint(jwk) do
    {_meta, params} = JOSE.JWK.to_map(jwk)
    canonical = ~s({"e":"#{params["e"]}","kty":"#{params["kty"]}","n":"#{params["n"]}"})

    Base.url_encode64(:crypto.hash(:sha256, canonical), padding: false)
  end

  # -- legacy dev-secret generation (moved from Router.generate_and_cache_secret) --

  defp generate_and_cache_dev_secret do
    global_key = {Smalt.ArmGateway.Router, :secret_lock}

    secret =
      :global.trans({global_key, node()}, fn ->
        case :persistent_term.get({Smalt.ArmGateway.Router, :sts_signing_secret}, :missing) do
          :missing ->
            secret =
              case Application.get_env(:smalt, :sts_signing_secret) do
                secret when is_binary(secret) and byte_size(secret) >= 32 ->
                  secret

                other when is_binary(other) ->
                  raise ArgumentError,
                        "smalt :sts_signing_secret must be >= 32 bytes when set (got #{byte_size(other)})"

                nil ->
                  if Application.get_env(:smalt, :prod, false) do
                    raise ArgumentError,
                          "smalt :sts_signing_secret must be configured in prod (Application.get_env(:smalt, :sts_signing_secret))"
                  else
                    :crypto.strong_rand_bytes(32)
                  end
              end

            :persistent_term.put({Smalt.ArmGateway.Router, :sts_signing_secret}, secret)
            secret

          secret ->
            secret
        end
      end)

    Joken.Signer.create("HS256", secret)
  end
end
