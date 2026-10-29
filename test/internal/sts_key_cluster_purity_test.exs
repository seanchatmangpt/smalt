defmodule Smalt.StsKeyClusterPurityTest do
  @moduledoc """
  BK-ARM2 message-passing-purity court: with `:cluster` enabled, the RS256 dev
  fallback (per-VM `JOSE.JWK.generate_key/1` cached in :persistent_term) must
  refuse — a token minted on pod A cannot verify on pod B. Fail-closed, typed.
  """
  use ExUnit.Case, async: false

  @cache {Smalt.Auth.StsKey, :key_state}

  test "cluster enabled + no :sts_signing_pem -> typed raise (per-VM key would diverge across pods)" do
    prev_cluster = Application.get_env(:smalt, :cluster)
    prev_pem = Application.get_env(:smalt, :sts_signing_pem)
    prev_prod = Application.get_env(:smalt, :prod)
    prev_state = :persistent_term.get(@cache, :missing)

    Application.put_env(:smalt, :cluster, enabled: true, dns_name: "smalt.test")
    Application.delete_env(:smalt, :sts_signing_pem)
    Application.put_env(:smalt, :prod, false)
    :persistent_term.erase(@cache)

    on_exit(fn ->
      if prev_cluster,
        do: Application.put_env(:smalt, :cluster, prev_cluster),
        else: Application.delete_env(:smalt, :cluster)

      if prev_pem,
        do: Application.put_env(:smalt, :sts_signing_pem, prev_pem),
        else: Application.delete_env(:smalt, :sts_signing_pem)

      if prev_prod,
        do: Application.put_env(:smalt, :prod, prev_prod),
        else: Application.delete_env(:smalt, :prod)

      if prev_state == :missing,
        do: :persistent_term.erase(@cache),
        else: :persistent_term.put(@cache, prev_state)
    end)

    assert_raise ArgumentError, ~r/:cluster is enabled/, fn ->
      Smalt.Auth.StsKey.mode()
    end
  end
end
