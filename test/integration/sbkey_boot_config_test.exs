# SBKEY (M4 boot-config defect): a dev boot without an explicit :sb_shared_key
# must sign with the deterministic dev_env-derived key
# (base64(sha256(hostname <> "smalt-dev-sb")), 44 bytes >= the 32-byte floor),
# so real clients that derive the same key (scripts/dev_env.sh) can do CBS SAS
# signing against a plain dev boot. A 12-byte configured key is refused at boot
# with a typed error (SasVerifier.validate_boot_key!/0) — never silently
# accepted. Chicago: real SasVerifier, real HMAC sign+verify, no mocks.
defmodule Smalt.Integration.SbkeyBootConfigTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.SasVerifier

  @queue "sbkey-floor-queue"

  test "nil config -> derived dev key (44B), real sign+verify passes" do
    with_nil_key(fn ->
      :persistent_term.erase({SasVerifier, :dev_key})

      key = SasVerifier.shared_key()

      # Same derivation shape as scripts/dev_env.sh:substrate.sh.
      {:ok, hostname} = :inet.gethostname()
      expected = Base.encode64(:crypto.hash(:sha256, hostname ++ 'smalt-dev-sb'))

      assert key == expected
      assert byte_size(key) >= 32

      # Real sign+verify round-trip through the same HMAC the broker CBS gate
      # runs — signing with the derived key is no longer impossible.
      sr = SasVerifier.endpoint() <> "/" <> @queue
      se = System.system_time(:second) + 3_600

      sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))
      token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

      assert {:ok, _claims} = SasVerifier.verify(token, SasVerifier.endpoint())
    end)
  end

  test "12-byte configured key is refused at boot with a typed error" do
    Application.put_env(:smalt, :sb_shared_key, "ws8sharedkey")

    try do
      assert_raise ArgumentError, ~r/:sb_shared_key/, fn ->
        SasVerifier.validate_boot_key!()
      end
    after
      Application.delete_env(:smalt, :sb_shared_key)
    end
  end

  # KD-131 runtime divergence unchanged: a sub-floor key still never reaches
  # the HMAC as-is — shared_key/0 falls back to the (now deterministic) dev key.
  test "12-byte configured key never reaches the HMAC; runtime fallback still typed" do
    Application.put_env(:smalt, :sb_dev_probe, nil)
    Application.put_env(:smalt, :sb_shared_key, "ws8sharedkey")

    try do
      :persistent_term.erase({SasVerifier, :dev_key})
      refute SasVerifier.shared_key() == "ws8sharedkey"
      assert byte_size(SasVerifier.shared_key()) >= 32
    after
      Application.delete_env(:smalt, :sb_shared_key)
      Application.delete_env(:smalt, :sb_dev_probe)
      :persistent_term.erase({SasVerifier, :dev_key})
    end
  end

  defp with_nil_key(fun) do
    previous = Application.get_env(:smalt, :sb_shared_key)
    Application.delete_env(:smalt, :sb_shared_key)

    try do
      fun.()
    after
      if previous, do: Application.put_env(:smalt, :sb_shared_key, previous)
      :persistent_term.erase({SasVerifier, :dev_key})
    end
  end
end
