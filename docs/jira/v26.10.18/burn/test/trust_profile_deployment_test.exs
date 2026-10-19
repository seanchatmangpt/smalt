defmodule Smalt.TrustProfile.DeploymentTest do
  # Status: no callers anywhere on HEAD (dead-code suspect per the wave audit).
  # KEPT: closed-enum validate/2 is AAIF-pack capital about to be wired by the
  # compliance lane; the module stays fenced by this suite until then.
  use ExUnit.Case, async: false

  alias Smalt.TrustProfile.Deployment

  describe "profiles/0" do
    test "closed enum" do
      assert Deployment.profiles() == [:loopback_dev, :sovereign_enterprise]
    end
  end

  describe "validate/2" do
    test "loopback_dev admits anonymous config, naming the relaxation as a finding" do
      {:ok, %{findings: findings}} =
        Deployment.validate(:loopback_dev, %{
          auth_mode: :anonymous,
          tls: false,
          sb_shared_key: nil
        })

      assert Enum.any?(findings, &(&1 =~ "anonymous"))
    end

    test "loopback_dev admits enforce config without the anonymous finding" do
      {:ok, %{findings: findings}} =
        Deployment.validate(:loopback_dev, %{auth_mode: :enforce, tls: true, sb_shared_key: "k"})

      refute Enum.any?(findings, &(&1 =~ "anonymous"))
    end

    test "sovereign_enterprise requires :enforce auth" do
      assert {:refused, reasons} =
               Deployment.validate(:sovereign_enterprise, %{
                 auth_mode: :anonymous,
                 tls: true,
                 sb_shared_key: "k"
               })

      assert Enum.any?(reasons, fn {reason, _} -> reason == :missing_auth_enforce end)
    end

    test "sovereign_enterprise requires TLS enabled (:auto refused as self-signed dev)" do
      assert {:refused, reasons} =
               Deployment.validate(:sovereign_enterprise, %{
                 auth_mode: :enforce,
                 tls: :auto,
                 sb_shared_key: "k"
               })

      assert Enum.any?(reasons, fn {reason, _} -> reason == :tls_not_enabled end)
    end

    test "sovereign_enterprise requires a binary sb_shared_key" do
      assert {:refused, reasons} =
               Deployment.validate(:sovereign_enterprise, %{
                 auth_mode: :enforce,
                 tls: true,
                 sb_shared_key: nil
               })

      assert Enum.any?(reasons, fn {reason, _} -> reason == :sb_shared_key_missing end)
    end

    test "sovereign_enterprise admits a fully hardened config" do
      assert {:ok, %{findings: findings}} =
               Deployment.validate(:sovereign_enterprise, %{
                 auth_mode: :enforce,
                 tls: true,
                 sb_shared_key: "k"
               })

      assert is_list(findings)
    end

    test "unknown profile refused" do
      assert {:refused, [{:unknown_profile, _}]} =
               Deployment.validate(:paranoid, %{auth_mode: :enforce})
    end

    test "non-atom-keyed config refused, never coerced" do
      assert {:refused, [{:bad_config, detail}]} =
               Deployment.validate(:loopback_dev, %{"auth_mode" => :enforce})

      assert detail =~ "non-atom"
    end

    test "non-map config refused" do
      assert {:refused, [{:bad_config, _}]} = Deployment.validate(:loopback_dev, "nope")
    end
  end

  describe "current_config/0 never emits nil :tls" do
    test "tls is true/false/:auto, never nil" do
      config = Deployment.current_config()
      assert config.tls in [true, false, :auto]
      assert config.auth_mode in [:enforce, :anonymous]
    end
  end
end
