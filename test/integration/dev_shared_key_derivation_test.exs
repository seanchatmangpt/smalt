defmodule Smalt.DevSharedKeyDerivationTest do
  @moduledoc """
  KD-S5 / KD-W01 regression pin: the per-host dev SAS shared key must be a
  SINGLE derivation, normalized to the short hostname on both the verifier
  (`SasVerifier.dev_shared_key/0`) and every producer side (dev_env.sh /
  substrate.sh). Before the fix, `$(hostname)` = "Mac.lan" (shell) vs the
  beam's short host "Mac" desynchronized producer and verifier, so every SDK
  send/read on the 5673 EH plane answered 401 INVALID_LOCAL_SAS.

  Chicago-style: real crypto, real `hostname`/`openssl` subprocesses — no
  mocks, no doubles.
  """

  use ExUnit.Case, async: false

  alias Smalt.Amqp.SasVerifier

  @suffix "smalt-dev-sb"

  defp shell_short_hostname do
    {out, 0} = System.cmd("hostname", ["-s"])
    String.trim_trailing(out)
  end

  defp shell_full_hostname do
    {out, 0} = System.cmd("hostname", [])
    String.trim_trailing(out)
  end

  defp shell_derivation(host) do
    {out, 0} =
      System.cmd("sh", ["-c", "printf '%s' \"$1\" | openssl dgst -sha256 -binary | base64", "sh", host <> @suffix])

    String.trim_trailing(out)
  end

  test "dev_shared_key/0 matches the documented shell derivation over the SHORT hostname" do
    assert SasVerifier.dev_shared_key() == shell_derivation(shell_short_hostname())
  end

  test "short and FQDN host forms normalize to the SAME key (the KD-S5 desync class)" do
    fqdn = shell_full_hostname()
    short = shell_short_hostname()

    # Only meaningful on a host whose `hostname` carries a domain part; the
    # normalization law itself is pinned regardless.
    assert Base.decode64!(SasVerifier.dev_shared_key()) |> byte_size() >= 32
    assert String.length(SasVerifier.dev_shared_key()) == 44

    normalized_fqdn = fqdn |> String.split(".", parts: 2) |> hd()
    assert normalized_fqdn == short or fqdn == short
    assert shell_derivation(normalized_fqdn) == SasVerifier.dev_shared_key()
  end

  test "shared_key/0 falls back to the canonical dev key when app env is unset/too small" do
    original = Application.get_env(:smalt, :sb_shared_key)

    Application.put_env(:smalt, :sb_shared_key, nil)
    assert SasVerifier.shared_key() == SasVerifier.dev_shared_key()

    # A configured key wins over the fallback (never silently replaced).
    configured = Base.encode64(:crypto.hash(:sha256, "configured-key" <> @suffix))
    Application.put_env(:smalt, :sb_shared_key, configured)
    assert SasVerifier.shared_key() == configured

    case original do
      nil -> Application.delete_env(:smalt, :sb_shared_key)
      key -> Application.put_env(:smalt, :sb_shared_key, key)
    end
  end

  test "a SAS token signed with the shell-derived short-host key HMAC-verifies against the dev key" do
    key = SasVerifier.dev_shared_key()
    sr = "sb://127.0.0.1:5673/eventhubs/dev-hub"
    se = Integer.to_string(System.system_time(:second) + 3600)
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))
    assert byte_size(Base.decode64!(sig)) == 32

    # Cross-implementation: the openssl-side derivation of the same host must
    # produce an identical HMAC over the same string-to-sign.
    shell_key = shell_derivation(shell_short_hostname())
    assert shell_key == key

    shell_sig =
      System.cmd("sh", [
        "-c",
        ~s(printf '%s\\n%s' "$1" "$2" | openssl dgst -sha256 -hmac "$3" -binary | base64),
        "sh",
        sr,
        se,
        key
      ])

    {out, 0} = shell_sig

    assert String.trim_trailing(out) == sig
  end
end
