defmodule Smalt.TLSTest do
  use ExUnit.Case, async: false

  import Smalt.TLS

  @cert "tmp/dev-cert.pem"
  @key "tmp/dev-key.pem"
  @cn_oid {2, 5, 4, 3}

  defp with_config(overrides, fun) do
    saved =
      for k <- [:tls, :tls_certfile, :tls_keyfile] do
        {k, Application.get_env(:smalt, k)}
      end

    for {k, v} <- overrides do
      if v == :delete, do: Application.delete_env(:smalt, k), else: Application.put_env(:smalt, k, v)
    end

    try do
      fun.()
    after
      for {k, v} <- saved do
        if v == nil, do: Application.delete_env(:smalt, k), else: Application.put_env(:smalt, k, v)
      end
    end
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(l)
    :ok = :gen_tcp.close(l)
    port
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 200, "tls-ok")
  end

  describe "generate_dev_cert_pem/0" do
    test "produces parseable PEM with CN and SAN 127.0.0.1 + localhost" do
      assert {:ok, cert_pem, key_pem} = generate_dev_cert_pem()

      assert [{:"Certificate", der, :not_encrypted}] = :public_key.pem_decode(cert_pem)
      assert [{:RSAPrivateKey, _, :not_encrypted}] = :public_key.pem_decode(key_pem)

      cert = :public_key.der_decode(:"Certificate", der)
      otp = :public_key.pkix_decode_cert(der, :otp)
      assert extract_cn(otp) == ~c'127.0.0.1'

      sans = extract_san(otp)
      assert {4, <<127, 0, 0, 1>>} in sans
      assert {2, ~c'localhost'} in sans
    end

    test "self-signature verifies" do
      {:ok, cert_pem, _} = generate_dev_cert_pem()
      [{_, der, :not_encrypted}] = :public_key.pem_decode(cert_pem)
      cert = :public_key.der_decode(:"Certificate", der)
      tbs = elem(cert, 1)
      spki_der = elem(elem(tbs, 7), 2)
      pubkey = :public_key.der_decode(:RSAPublicKey, spki_der)
      assert :public_key.pkix_verify(der, pubkey)
    end
  end

  describe "ensure_dev_cert/0" do
    test "explicit certfile/keyfile used when files exist" do
      {:ok, _, _} = generate_dev_cert_pem() |> then(fn {:ok, c, k} -> File.write!(@cert, c); File.write!(@key, k); {:ok, @cert, @key} end)

      with_config([tls_certfile: @cert, tls_keyfile: @key, tls: :delete], fn ->
        assert {:ok, @cert, @key} = ensure_dev_cert()
        assert scheme() == :https
      end)
    end

    test ":auto generates cert into tmp/ and is cached by mtime" do
      File.rm(@cert)
      File.rm(@key)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        assert {:ok, cert, key} = ensure_dev_cert()
        assert File.regular?(cert) and File.regular?(key)
        assert scheme() == :https
        assert Bitwise.band(File.stat!(key).mode, 0o777) == 0o600

        mtime = File.stat!(cert).mtime
        assert {:ok, ^cert, ^key} = ensure_dev_cert()
        assert File.stat!(cert).mtime == mtime
      end)
    after
      File.rm(@cert)
      File.rm(@key)
    end

    test "tls: false disables" do
      with_config([tls: false, tls_certfile: nil, tls_keyfile: nil], fn ->
        assert {:error, :tls_disabled} = ensure_dev_cert()
        assert scheme() == :http
      end)
    end
  end

  describe "bandit_opts/2" do
    test "https opts when TLS enabled, http when disabled" do
      File.rm(@cert)
      File.rm(@key)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        opts = bandit_opts(__MODULE__, 9999)
        assert opts[:scheme] == :https
        assert opts[:certfile] |> List.to_string() |> Path.expand() == Path.expand(@cert)
        assert opts[:plug] == __MODULE__
      end)

      with_config([tls: false, tls_certfile: nil, tls_keyfile: nil], fn ->
        opts = bandit_opts(__MODULE__, 9999)
        assert opts[:scheme] == :http
        refute Keyword.has_key?(opts, :certfile)
      end)
    end
  end

  test "Bandit https boot + :ssl connect + :httpc round-trip" do
    File.rm(@cert)
    File.rm(@key)

    with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
      port = free_port()
      opts = bandit_opts(__MODULE__, port)

      start_supervised!({Bandit, opts})

      # This OTP's ssl client rejects any self-signed peer cert as anchor
      # (selfsigned_peer) unless a verify_fun accepts it — mirrors a local dev
      # client pinning the self-signed dev cert.
      # Arity-3 form: fun(peer_cert, event, user_state). Accepts the self-signed
      # anchor the OTP client otherwise rejects (selfsigned_peer) — mirrors a
      # local dev client pinning the self-signed dev cert.
      verify_fun = fn
        _cert, {:bad_cert, :selfsigned_peer}, acc -> {:valid, acc}
        _cert, {:extension, _}, acc -> {:unknown, acc}
        _cert, {:valid, _}, acc -> {:valid, acc}
      end

      # OTP :ssl requires the {fun, initial_user_state} tuple form.
      {:ok, ssl_sock} =
        :ssl.connect(~c"localhost", port,
          verify: :verify_peer,
          active: false,
          cacertfile: String.to_charlist(Path.expand(@cert)),
          depth: 1,
          server_name_indication: ~c"localhost",
          verify_fun: {verify_fun, :ok}
        )

      :ok = :ssl.send(ssl_sock, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      # ssl recv requires a nonzero length (unlike gen_tcp); "HTTP/1.1 200 OK"
      # is exactly 15 bytes.
      assert {:ok, data} = :ssl.recv(ssl_sock, 15, 5_000)
      assert to_string(data) =~ "HTTP/1.1 200 OK"

      # drain the rest (headers + body "tls-ok") until the server closes
      rest = recv_all(ssl_sock, to_string(data))
      assert rest =~ "tls-ok"
      :ok = :ssl.close(ssl_sock)

      # :httpc round-trip with verify disabled
      :inets.start()
      :ssl.start()

      assert {:ok, {{_, 200, _}, _, body}} =
               :httpc.request(:get, {~c"https://localhost:#{port}/", []}, [ssl: [verify: :verify_none]], [])

      assert to_string(body) == "tls-ok"
    end)
  after
    File.rm(@cert)
    File.rm(@key)
  end

  # -- helpers ----------------------------------------------------------------

  defp recv_all(sock, acc) do
    case :ssl.recv(sock, 0, 5_000) do
      {:ok, more} -> recv_all(sock, acc <> to_string(more))
      {:error, _} -> acc
    end
  end

  # OTPTBSCertificate tuple: tag, version, serial, signature, issuer, validity,
  # subject(6), spki(7), issuerUID(8), subjectUID(9), extensions(10)
  defp extract_cn(otp) do
    {:rdnSequence, [rdn | _]} = elem(elem(otp, 1), 6)
    [{:"AttributeTypeAndValue", @cn_oid, {:printableString, cn}}] = rdn
    cn
  end

  defp extract_san(otp) do
    exts = elem(elem(otp, 1), 10)
    {:"Extension", {2, 5, 29, 17}, _, der} = Enum.find(exts, &match?({:"Extension", {2, 5, 29, 17}, _, _}, &1))

    # The :otp decode already materializes extnValue as GeneralName entries.
    Enum.map(der, fn
      {:dNSName, name} -> {2, name}
      {:iPAddress, ip} -> {4, ip}
      other -> other
    end)
  end
end
