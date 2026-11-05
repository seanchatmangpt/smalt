defmodule Smalt.Aoq.Quic.CertsTest do
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Quic.Certs

  @pem "-----BEGIN CERTIFICATE-----\nZm9vYmFy\n-----END CERTIFICATE-----\n"
  # "foobar" base64

  test "pem_to_der extracts and decodes the first block" do
    assert {:ok, "foobar"} = Certs.pem_to_der(@pem)
  end

  test "pem_to_der ignores surrounding whitespace/newlines" do
    pem = "junk\n" <> @pem <> "trailing\n"
    assert {:ok, "foobar"} = Certs.pem_to_der(pem)
  end

  test "typed refusal: no PEM block" do
    assert {:error, {:cert_refusal, :no_pem_block}} = Certs.pem_to_der("hello world")
  end

  test "typed refusal: unterminated block" do
    assert {:error, {:cert_refusal, :unterminated_block}} =
             Certs.pem_to_der("-----BEGIN CERTIFICATE-----\nZm9vYmFy\n")
  end

  test "typed refusal: bad base64 body" do
    bad = "-----BEGIN CERTIFICATE-----\n!!!not base64!!!\n-----END CERTIFICATE-----\n"
    assert {:error, {:cert_refusal, :pem_body_not_base64}} = Certs.pem_to_der(bad)
  end

  test "pem_to_der! reads from disk, missing file is a typed refusal" do
    assert {:error, {:cert_refusal, {:pem_read_failed, :enoent}}} =
             Certs.pem_to_der!("/tmp/lane4-nonexistent-#{:erlang.unique_integer()}.pem")

    path = Path.join(System.tmp_dir(), "lane4-cert-#{:erlang.unique_integer()}.pem")
    File.write!(path, @pem)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, "foobar"} = Certs.pem_to_der!(path)
  end

  test "real openssl-minted ECDSA leaf extracts to valid DER (non-empty, starts 0x30)" do
    path = "/tmp/lane4-certs/quic-cert.pem"

    if File.exists?(path) do
      assert {:ok, der} = Certs.pem_to_der!(path)
      assert byte_size(der) > 100
      assert binary_part(der, 0, 1) == <<0x30>>
    else
      fling = "quic leaf cert not minted into /tmp/lane4-certs (gen_dev_cert.sh sandbox)"
      IO.puts("[SKIP-loud] #{fling}")
    end
  end
end
