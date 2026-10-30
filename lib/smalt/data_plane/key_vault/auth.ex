defmodule Smalt.DataPlane.KeyVault.Auth do
  @moduledoc """
  Key Vault identity/challenge posture (KD-15) — the profile accessors the
  router consumes for the tokenless-401 challenge handshake.

  Law (KD-15, RFC 6750 §3 + ADAL/azure-core parity): a tokenless request to a
  Key Vault data-plane route is answered with `401` + an enriched
  `WWW-Authenticate: Bearer` challenge, and the SDK resends with the bearer
  token. The posture is mode-blind by default: `config :smalt, :keyvault,
  challenge_mode: :strict_bearer` is the default even when the profile is not
  loaded. The single read surface the router consumes is
  `Smalt.Auth.Bearer.kv_challenge_mode/0`; the accessors here exist so each
  profile key has one named reader per surface, matching `api_version/0`.
  """

  @doc """
  The Key Vault data-plane API version served on `/:keys`+`/secrets` routes —
  `config :smalt, :keyvault, api_version: "7.4"` (identity-plane profile,
  config/env/az_prod_identity.exs). Default "7.4" when the profile is not
  loaded (`:all` boot), so the default boot is byte-identical. Consumed by
  the AKV api-version gate in `EgressRouter` (refusal-message example) and
  by the identity-plane court.
  """
  @spec api_version :: binary()
  def api_version do
    Keyword.get(Smalt.Config.keyvault(), :api_version, "7.4")
  end

  @doc """
  The Key Vault challenge posture — `config :smalt, :keyvault,
  challenge_mode: :strict_bearer`. See `Smalt.Auth.Bearer.kv_challenge_mode/0`
  (the single read surface the router consumes); this accessor exists so the
  profile key has one named reader per surface, matching `api_version/0`.
  """
  @spec challenge_mode :: :strict_bearer | atom()
  def challenge_mode do
    Keyword.get(Smalt.Config.keyvault(), :challenge_mode, :strict_bearer)
  end
end
