defmodule Smalt.ConfigAliasLawTest do
  use ExUnit.Case, async: false

  # R8: neutral-first env alias law. Every SMALT_* env read in
  # Smalt.Config resolves its AZURE_* alias first, legacy SMALT_* second,
  # identical defaults when neither is set. Behavior additive +
  # default-identical: legacy-only deployments are byte-unchanged.
  #
  # v26.10.31 inversion (WO-06): the POLARITY below is parameterized, not
  # hardcoded. Today (pre-flip): neutral prefix = "AZURE_", legacy prefix =
  # "SMALT_". The wave-19 flip (owned by the lane that regenerates
  # Smalt.Config.neutral_aliases/0) is a TWO-ATTRIBUTE change in this file:
  # swap the values of @neutral_prefix and @legacy_prefix. Every assertion
  # in this module derives from the attributes; none hardcodes a prefix.
  @neutral_prefix "SMALT_"
  @legacy_prefix "AZURE_"

  import Smalt.Config, only: [neutral_aliases: 0, neutral_env: 1]

  alias Smalt.Config

  @legacy_keys Map.keys(neutral_aliases())

  # Neutral-env names, derived from the prefix attributes (wave-19 flip
  # propagates here with zero edits).
  defp neutral(key), do: @neutral_prefix <> key
  defp legacy(key), do: @legacy_prefix <> key
  defp scrub_list do
    @legacy_keys ++
      Enum.map(
        ~w(ARM_RATE_LIMIT BIND_IP BLOB_ACCOUNT_KEY COSMOS_RU_LIMIT PLANES PROFILE SB_SHARED_KEY TLS_CERTFILE TLS_KEYFILE),
        &neutral/1
      )
  end

  setup do
    for k <- scrub_list(), do: System.delete_env(k)

    on_exit(fn ->
      for k <- scrub_list(), do: System.delete_env(k)
    end)

    :ok
  end

  test "alias table covers every census env_var entry" do
    for %{env_var: env_var} <- Config.census(), is_binary(env_var) do
      assert Map.has_key?(neutral_aliases(), env_var),
             "census env_var #{env_var} has no AZURE_* alias"
    end
  end

  test "every alias is a pure legacy -> neutral prefix swap" do
    legacy_size = String.length(@legacy_prefix)

    for {legacy, neutral} <- neutral_aliases() do
      assert String.starts_with?(legacy, @legacy_prefix)
      assert neutral == @neutral_prefix <> String.slice(legacy, legacy_size..-1//1)
    end
  end

  test "polarity pin: the alias table's keys carry the LEGACY prefix and its values the NEUTRAL prefix (wave-19 flip swaps the two attributes above, not this test)" do
    for {legacy, neutral} <- neutral_aliases() do
      refute String.starts_with?(legacy, @neutral_prefix),
             "alias key #{legacy} must not already carry the neutral prefix"
      refute String.starts_with?(neutral, @legacy_prefix),
             "alias value #{neutral} must not already carry the legacy prefix"
    end
  end

  test "neutral resolves via neutral_env" do
    System.put_env(neutral("BIND_IP"), "10.1.2.3")
    assert neutral_env(legacy("BIND_IP")) == "10.1.2.3"
    assert Config.bind_ip() == "10.1.2.3"
  end

  test "legacy still resolves (default-identical)" do
    System.put_env(legacy("BIND_IP"), "10.9.9.9")
    assert Config.bind_ip() == "10.9.9.9"
  end

  test "neutral wins on conflict" do
    System.put_env(neutral("BIND_IP"), "10.1.2.3")
    System.put_env(legacy("BIND_IP"), "10.9.9.9")
    assert Config.bind_ip() == "10.1.2.3"
  end

  test "defaults unchanged when neither set" do
    assert Config.bind_ip() == nil
  end

  test "profile: neutral, legacy, conflict, default" do
    System.put_env(neutral("PROFILE"), "strict")
    assert Config.profile() == :strict

    System.delete_env(neutral("PROFILE"))
    System.put_env(legacy("PROFILE"), "azure_parity")
    assert Config.profile() == :azure_parity

    System.put_env(neutral("PROFILE"), "strict")
    assert Config.profile() == :strict

    System.delete_env(neutral("PROFILE"))
    System.delete_env(legacy("PROFILE"))
    assert Config.profile() == :unbounded
  end

  test "arm_rate_limit: neutral env beats profile and legacy" do
    System.put_env(neutral("PROFILE"), "strict")
    System.put_env(neutral("ARM_RATE_LIMIT"), "42")
    System.put_env(legacy("ARM_RATE_LIMIT"), "7")
    assert Config.arm_rate_limit() == 42

    System.delete_env(neutral("ARM_RATE_LIMIT"))
    assert Config.arm_rate_limit() == 7
  end

  test "cosmos_ru_limit: neutral env resolves" do
    System.put_env(neutral("COSMOS_RU_LIMIT"), "99")
    assert Config.cosmos_ru_limit() == 99
  end

  test "blob_account_key: app env still wins over neutral env (override order unchanged)" do
    Application.put_env(:smalt, :blob_account_key, "app-env-key")
    System.put_env(neutral("BLOB_ACCOUNT_KEY"), "neutral-key")

    assert Config.blob_account_key() == "app-env-key"

    Application.delete_env(:smalt, :blob_account_key)
    assert Config.blob_account_key() == "neutral-key"
  end

  test "unknown profile through the neutral alias refuses with the typed error" do
    System.put_env(@neutral_prefix <> "PROFILE", "nonsense")

    assert_raise ArgumentError, Regex.compile!(@neutral_prefix <> "PROFILE"), fn ->
      Config.profile()
    end
  end
end
