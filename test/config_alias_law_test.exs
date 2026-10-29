defmodule Smalt.ConfigAliasLawTest do
  use ExUnit.Case, async: false

  # R8: neutral-first env alias law. Every SMALT_* env read in
  # Smalt.Config resolves its AZURE_* alias first, legacy SMALT_* second,
  # identical defaults when neither is set. Behavior additive +
  # default-identical: legacy-only deployments are byte-unchanged.

  import Smalt.Config, only: [neutral_aliases: 0, neutral_env: 1]

  alias Smalt.Config

  @legacy_keys Map.keys(neutral_aliases())

  setup do
    for k <- @legacy_keys ++ ~w(AZURE_ARM_RATE_LIMIT AZURE_BIND_IP AZURE_BLOB_ACCOUNT_KEY AZURE_COSMOS_RU_LIMIT AZURE_PLANES AZURE_PROFILE AZURE_SB_SHARED_KEY AZURE_TLS_CERTFILE AZURE_TLS_KEYFILE) do
      System.delete_env(k)
    end

    on_exit(fn ->
      for k <- @legacy_keys ++ ~w(AZURE_ARM_RATE_LIMIT AZURE_BIND_IP AZURE_BLOB_ACCOUNT_KEY AZURE_COSMOS_RU_LIMIT AZURE_PLANES AZURE_PROFILE AZURE_SB_SHARED_KEY AZURE_TLS_CERTFILE AZURE_TLS_KEYFILE) do
        System.delete_env(k)
      end
    end)

    :ok
  end

  test "alias table covers every census env_var entry" do
    for %{env_var: env_var} <- Config.census(), is_binary(env_var) do
      assert Map.has_key?(neutral_aliases(), env_var),
             "census env_var #{env_var} has no AZURE_* alias"
    end
  end

  test "every alias is a pure SMALT_ -> AZURE_ prefix swap" do
    for {legacy, neutral} <- neutral_aliases() do
      assert String.starts_with?(legacy, "SMALT_")
      assert neutral == "AZURE_" <> String.slice(legacy, 6..-1//1)
    end
  end

  test "neutral resolves via neutral_env" do
    System.put_env("AZURE_BIND_IP", "10.1.2.3")
    assert neutral_env("SMALT_BIND_IP") == "10.1.2.3"
    assert Config.bind_ip() == "10.1.2.3"
  end

  test "legacy still resolves (default-identical)" do
    System.put_env("SMALT_BIND_IP", "10.9.9.9")
    assert Config.bind_ip() == "10.9.9.9"
  end

  test "neutral wins on conflict" do
    System.put_env("AZURE_BIND_IP", "10.1.2.3")
    System.put_env("SMALT_BIND_IP", "10.9.9.9")
    assert Config.bind_ip() == "10.1.2.3"
  end

  test "defaults unchanged when neither set" do
    assert Config.bind_ip() == nil
  end

  test "profile: neutral, legacy, conflict, default" do
    System.put_env("AZURE_PROFILE", "strict")
    assert Config.profile() == :strict

    System.delete_env("AZURE_PROFILE")
    System.put_env("SMALT_PROFILE", "azure_parity")
    assert Config.profile() == :azure_parity

    System.put_env("AZURE_PROFILE", "strict")
    assert Config.profile() == :strict

    System.delete_env("AZURE_PROFILE")
    System.delete_env("SMALT_PROFILE")
    assert Config.profile() == :unbounded
  end

  test "arm_rate_limit: neutral env beats profile and legacy" do
    System.put_env("AZURE_PROFILE", "strict")
    System.put_env("AZURE_ARM_RATE_LIMIT", "42")
    System.put_env("SMALT_ARM_RATE_LIMIT", "7")
    assert Config.arm_rate_limit() == 42

    System.delete_env("AZURE_ARM_RATE_LIMIT")
    assert Config.arm_rate_limit() == 7
  end

  test "cosmos_ru_limit: neutral env resolves" do
    System.put_env("AZURE_COSMOS_RU_LIMIT", "99")
    assert Config.cosmos_ru_limit() == 99
  end

  test "blob_account_key: app env still wins over neutral env (override order unchanged)" do
    Application.put_env(:smalt, :blob_account_key, "app-env-key")
    System.put_env("AZURE_BLOB_ACCOUNT_KEY", "neutral-key")

    assert Config.blob_account_key() == "app-env-key"

    Application.delete_env(:smalt, :blob_account_key)
    assert Config.blob_account_key() == "neutral-key"
  end

  test "unknown profile through the neutral alias refuses with the typed error" do
    System.put_env("AZURE_PROFILE", "nonsense")

    assert_raise ArgumentError, ~r/AZURE_PROFILE/, fn -> Config.profile() end
  end
end
