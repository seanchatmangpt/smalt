defmodule Smalt.TrustProfile.Deployment do
  @moduledoc """
  AAIF deployment-profile tailoring for Smalt, adapted from the
  `aaif-profile-tailoring-pack` (closed enums; anything outside the enum is
  refused, never coerced).

  Two closed profiles:

  * `:loopback_dev` — local development. Anonymous auth, plaintext or
    auto-TLS, no shared key. Relaxations are reported as named findings, not
    refused: a dev profile is tailored by naming each relaxation explicitly.
  * `:sovereign_enterprise` — hardened deployment: `:enforce` auth, TLS
    enabled (not `:auto`, which self-signs a dev cert), and a binary
    `:sb_shared_key` configured.

  `validate/2` is a pure function of (profile, config map) — with one bounded
  exception: a `nil` `:tls` key falls back to checking explicit certfile
  presence on disk (`certfiles_present?/0`, which does read the application
  environment). `current_config/0` never emits a `nil` `:tls`, so the
  `current_config/0`-fed path is fully pure. Callers that want the
  checked-against-live-config flavor pass `current_config/0` as config.
  The AAIF pack's law holds: every non-admission is a typed refusal, never a
  coercion.
  """

  @type deployment_profile :: :loopback_dev | :sovereign_enterprise
  @type config :: map

  @doc "The closed enum of deployment profiles."
  @spec profiles() :: [deployment_profile()]
  def profiles, do: [:loopback_dev, :sovereign_enterprise]

  @doc """
  Live substrate config snapshot (auth_mode, tls, sb_shared_key) for use as
  the `config` argument of `validate/2`. TLS is read from `:smalt, :tls`
  (`true` / `false` / `:auto`) with the `Smalt.TLS` certfile-based fallback:
  when explicit certfiles exist on disk, TLS counts as enabled even if the
  `:tls` key is unset.
  """
  @spec current_config() :: config()
  def current_config do
    %{
      auth_mode: Application.get_env(:smalt, :auth_mode, :enforce),
      tls: effective_tls(),
      sb_shared_key: Application.get_env(:smalt, :sb_shared_key)
    }
  end

  @doc """
  Validates a deployment profile against a substrate config map. Pure.

  Returns:

    * `{:ok, %{profile: profile, config: config, findings: [String.t()]}}` —
      admitted; `findings` names the active relaxations (loopback) or states
      all hardening requirements met (enterprise).
    * `{:refused, [{reason :: atom, detail :: String.t()}]}` — closed-enum
      violation or hardening gap.

  Matrix: `:loopback_dev` admits every config, naming relaxations as
  findings. `:sovereign_enterprise` requires `auth_mode == :enforce`, TLS
  enabled (true or explicit existing certfiles; `:auto` refused as
  self-signed dev), and a binary `sb_shared_key`.
  """
  @spec validate(term, term) ::
          {:ok, %{profile: deployment_profile(), config: config(), findings: [String.t()]}}
          | {:refused, [{atom, String.t()}]}
  def validate(profile, config)

  def validate(profile, config)
      when is_map(config) and profile in [:loopback_dev, :sovereign_enterprise] do
    if Enum.all?(Map.keys(config), &is_atom/1) do
      do_validate(profile, config)
    else
      {:refused,
       [
         {:bad_config,
          "config keys must be atoms (got non-atom keys: #{inspect(Map.keys(config) |> Enum.reject(&is_atom/1))}); string-keyed configs are coerced-to-empty under atom Access and are refused, never coerced"}
       ]}
    end
  end

  def validate(profile, _config) when profile not in [:loopback_dev, :sovereign_enterprise] do
    {:refused,
     [
       {:unknown_profile,
        "profile must be one of #{inspect(profiles())}, got #{inspect(profile)}"}
     ]}
  end

  def validate(_profile, config) do
    {:refused, [{:bad_config, "config must be a map, got #{inspect(config)}"}]}
  end

  ## Internals

  defp do_validate(:loopback_dev, config) do
    findings =
      []
      |> maybe_finding(
        config[:auth_mode] == :anonymous,
        "auth_mode is :anonymous — no bearer enforcement; local-only"
      )
      |> maybe_finding(
        config[:auth_mode] != :anonymous,
        "auth_mode is #{inspect(config[:auth_mode])} — bearer enforcement active"
      )
      |> maybe_finding(
        config[:tls] == false,
        "tls is false — plaintext HTTP; local-only"
      )
      |> maybe_finding(
        config[:tls] == :auto,
        "tls is :auto — self-signed dev cert; local-only"
      )
      |> maybe_finding(
        config[:tls] == true,
        "tls is true — TLS enabled in a dev profile (unusual)"
      )
      |> maybe_finding(
        is_binary(config[:sb_shared_key]),
        "sb_shared_key present — SAS HMAC verification active (unusual for loopback)"
      )
      |> maybe_finding(
        not is_binary(config[:sb_shared_key]),
        "sb_shared_key absent — no SAS HMAC shared key; local-only"
      )

    {:ok, %{profile: :loopback_dev, config: config, findings: findings}}
  end

  defp do_validate(:sovereign_enterprise, config) do
    violations =
      []
      |> require(
        config[:auth_mode] == :enforce,
        {:missing_auth_enforce,
         "sovereign-enterprise requires auth_mode == :enforce; got #{inspect(config[:auth_mode])}"}
      )
      |> require(
        tls_enabled?(config),
        {:tls_not_enabled,
         "sovereign-enterprise requires TLS enabled or explicit certfiles; got #{inspect(config[:tls])}"}
      )
      |> require(
        is_binary(config[:sb_shared_key]),
        {:sb_shared_key_missing,
         "sovereign-enterprise requires a binary :sb_shared_key; got #{inspect(config[:sb_shared_key])}"}
      )

    if violations == [] do
      {:ok,
       %{
         profile: :sovereign_enterprise,
         config: config,
         findings: ["all hardening requirements met"]
       }}
    else
      {:refused, violations}
    end
  end

  defp require(acc, true, _violation), do: acc
  defp require(acc, false, violation), do: [violation | acc]

  defp maybe_finding(acc, true, text), do: [text | acc]
  defp maybe_finding(acc, false, _text), do: acc

  defp tls_enabled?(config) do
    case config[:tls] do
      true -> true
      nil -> certfiles_present?()
      :auto -> false
      _ -> false
    end
  end

  defp certfiles_present? do
    cert = Application.get_env(:smalt, :tls_certfile)
    key = Application.get_env(:smalt, :tls_keyfile)
    is_binary(cert) and is_binary(key) and File.exists?(cert) and File.exists?(key)
  end

  defp effective_tls do
    case Application.get_env(:smalt, :tls, :auto) do
      :auto ->
        if certfiles_present?(), do: true, else: :auto

      other ->
        other
    end
  end
end
