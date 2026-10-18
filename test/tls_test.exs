defmodule Smalt.TLSTest do
  use ExUnit.Case, async: false

  import Smalt.TLS

  @cn_oid {2, 5, 4, 3}

  defp with_config(overrides, fun) do
    saved =
      for k <- [:tls, :tls_certfile, :tls_keyfile] do
        {k, Application.get_env(:smalt, k)}
      end

    for {k, v} <- overrides do
      if v == :delete,
        do: Application.delete_env(:smalt, k),
        else: Application.put_env(:smalt, k, v)
    end

    try do
      fun.()
    after
      for {k, v} <- saved do
        if v == nil,
          do: Application.delete_env(:smalt, k),
          else: Application.put_env(:smalt, k, v)
      end
    end
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(l)
    :ok = :gen_tcp.close(l)
    port
  end

  defp seat_dir, do: Path.expand("tmp/dev-certs")

  # R185d: per-seat cleanup ONLY. The old `rm_seat_cache` deleted the whole
  # tmp/dev-certs dir, so two concurrent runs (or any lane sweeping the dir)
  # deleted other seats' live certs mid-run -> :enoent. Now each test deletes
  # exactly the files it created: dev-cert-<key>.pem / dev-key-<key>.pem plus
  # their .tmp-* publish siblings. The dir itself is never removed.
  defp rm_seat(key) do
    {cert, keyf} = dev_cert_paths(key)
    File.rm_rf(cert)
    File.rm_rf(keyf)

    for leftover <-
          Path.wildcard(Path.join(seat_dir(), "dev-cert-#{key}.pem.tmp-*")) ++
            Path.wildcard(Path.join(seat_dir(), "dev-key-#{key}.pem.tmp-*")) do
      File.rm(leftover)
    end

    :ok
  end

  # R178f compile-freeze unblock: the R185d rewrite removed this helper while
  # 21 call sites still referenced it (mid-flight), aborting the whole suite's
  # compile. Restored verbatim from HEAD; R185d owns migrating the call sites.
  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 200, "tls-ok")
  end

  describe "generate_dev_cert_pem/0" do
    test "produces parseable PEM with CN and SAN 127.0.0.1 + localhost" do
      assert {:ok, cert_pem, key_pem} = generate_dev_cert_pem()

      assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(cert_pem)
      assert [{:RSAPrivateKey, _, :not_encrypted}] = :public_key.pem_decode(key_pem)

      otp = :public_key.pkix_decode_cert(der, :otp)
      assert extract_cn(otp) == ~c'127.0.0.1'

      sans = extract_san(otp)
      assert {4, <<127, 0, 0, 1>>} in sans
      assert {2, ~c'localhost'} in sans
    end

    test "self-signature verifies" do
      {:ok, cert_pem, _} = generate_dev_cert_pem()
      [{_, der, :not_encrypted}] = :public_key.pem_decode(cert_pem)
      cert = :public_key.der_decode(:Certificate, der)
      tbs = elem(cert, 1)
      spki_der = elem(elem(tbs, 7), 2)
      pubkey = :public_key.der_decode(:RSAPublicKey, spki_der)
      assert :public_key.pkix_verify(der, pubkey)
    end
  end

  describe "dev_cert_paths/1 (TLS-261014-01)" do
    test "distinct lane keys yield distinct, seat-local paths" do
      {c1, k1} = dev_cert_paths(8443)
      {c2, k2} = dev_cert_paths(9443)
      {c3, k3} = dev_cert_paths()

      assert c1 != c2 and k1 != k2
      assert c1 != c3 and k1 != k3
      assert Path.dirname(c1) == seat_dir()
      assert c1 =~ ~r/dev-cert-.*\.pem$/
      assert k1 =~ ~r/dev-key-.*\.pem$/
    end

    test "default key is OS-pid keyed, or exactly SMALT_TLS_LANE when set" do
      {cert, _} = dev_cert_paths()
      refute cert == Path.expand("tmp/dev-cert.pem")

      if System.get_env("SMALT_TLS_LANE") do
        raise "SMALT_TLS_LANE must not be set in the test env (pin depends on both branches)"
      end

      assert Path.basename(cert) == "dev-cert-pid-#{:os.getpid()}.pem"

      # SMALT_TLS_LANE branch: must override the pid key exactly
      System.put_env("SMALT_TLS_LANE", "mutation-kill-lane")

      try do
        {cert2, key2} = dev_cert_paths()
        assert Path.basename(cert2) == "dev-cert-mutation-kill-lane.pem"
        assert Path.basename(key2) == "dev-key-mutation-kill-lane.pem"
      after
        System.delete_env("SMALT_TLS_LANE")
      end
    end
  end

  describe "ensure_dev_cert/0" do
    test "explicit certfile/keyfile used when files exist" do
      {cert, key} = dev_cert_paths("explicit-test-#{:os.getpid()}")
      {:ok, c, k} = generate_dev_cert_pem()
      File.mkdir_p(Path.dirname(cert))
      File.write!(cert, c)
      File.write!(key, k)

      with_config([tls_certfile: cert, tls_keyfile: key, tls: :delete], fn ->
        assert {:ok, ^cert, ^key} = ensure_dev_cert()
        assert scheme() == :https
      end)
    after
      {rc, rk} = dev_cert_paths("explicit-test-#{:os.getpid()}")
      File.rm(rc)
      File.rm(rk)
    end

    test ":auto generates cert into a port-keyed seat path and is cached by mtime" do
      port = free_port()
      on_exit(fn -> rm_seat(port) end)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        assert {:ok, cert, key} = ensure_dev_cert(port)
        assert Path.basename(cert) == "dev-cert-#{port}.pem"
        assert File.regular?(cert) and File.regular?(key)
        assert scheme(port) == :https
        assert Bitwise.band(File.stat!(key).mode, 0o777) == 0o600

        mtime = File.stat!(cert).mtime
        assert {:ok, ^cert, ^key} = ensure_dev_cert(port)
        assert File.stat!(cert).mtime == mtime
      end)
    end

    test "tls: false disables" do
      with_config([tls: false, tls_certfile: nil, tls_keyfile: nil], fn ->
        assert {:error, :tls_disabled} = ensure_dev_cert()
        assert scheme() == :http
      end)
    end

    test "corrupt cached cert regenerates (typed recovery, lens-6 pin)" do
      port = free_port()
      on_exit(fn -> rm_seat(port) end)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        {:ok, cert, _key} = ensure_dev_cert(port)
        File.write!(cert, "-----BEGIN CERTIFICATE-----\nbroken\n-----END CERTIFICATE-----\n")
        assert {:ok, cert2, _} = ensure_dev_cert(port)
        assert cert2 == cert
        assert match?({:ok, _, _}, Smalt.TLS.ensure_dev_cert(port))
        # the file parses again after recovery
        {:ok, pem} = File.read(cert)
        assert match?([{:Certificate, _, :not_encrypted}], :public_key.pem_decode(pem))
      end)
    end
  end

  describe "bandit_opts/2" do
    test "https opts when TLS enabled, http when disabled" do
      port = free_port()
      on_exit(fn -> rm_seat(port) end)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        opts = bandit_opts(__MODULE__, port)
        assert opts[:scheme] == :https

        assert opts[:certfile] |> List.to_string() |> Path.expand() ==
                 Path.expand("tmp/dev-certs/dev-cert-#{port}.pem")

        assert opts[:plug] == __MODULE__
      end)

      with_config([tls: false, tls_certfile: nil, tls_keyfile: nil], fn ->
        opts = bandit_opts(__MODULE__, port)
        assert opts[:scheme] == :http
        refute Keyword.has_key?(opts, :certfile)
      end)
    end
  end

  # -- TLS-261014-01 falsifier + lifecycle fuzz ---------------------------------

  describe "concurrency falsifier (TLS-261014-01)" do
    test "paired boots: regenerator racing a boot across N=20 paired seats, zero crashes" do
      results =
        for _n <- 1..20 do
          port = free_port()

          with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
            # The "booting" seat resolves cert material while a regenerator
            # races it on the SAME seat key (worst case: shared-port fallback).
            # Pre-seed a truncated PEM so the boot goes down the regenerate
            # path (corrupt-cache recovery folded into the race).
            boot =
              Task.async(fn ->
                {c, _k} = Smalt.TLS.dev_cert_paths(port)
                File.mkdir_p(Path.dirname(c))
                File.write!(c, "trunc")

                case Smalt.TLS.ensure_dev_cert(port) do
                  {:ok, _, _} -> :ok
                  other -> other
                end
              end)

            # Racer: repeated publishes while a concurrent reader models a
            # booting listener (read cert then key, decode both, no rescue).
            # Under the atomic-publish fence the reader only ever sees whole
            # files; under in-place writes the cert-rename..key-write window
            # (mutant) yields torn reads — the witnessed Bandit-start crash.
            racer =
              Task.async(fn ->
                {c, k} = Smalt.TLS.dev_cert_paths(port)

                for _ <- 1..15 do
                  Smalt.TLS.write_dev_cert(c, k)
                  {:ok, cpem} = File.read(c)
                  {:ok, kpem} = File.read(k)
                  assert match?([{:Certificate, _, :not_encrypted}], :public_key.pem_decode(cpem))

                  assert match?(
                           [{:RSAPrivateKey, _, :not_encrypted}],
                           :public_key.pem_decode(kpem)
                         )
                end

                :ok
              end)

            r1 = Task.await(boot, 60_000)
            assert :ok = Task.await(racer, 60_000)

            case r1 do
              :ok -> :ok
              other -> other
            end
          end)
        end

      assert Enum.all?(results, &(&1 == :ok)),
             "crashes/seats: #{inspect(Enum.filter(results, &(&1 != :ok)), limit: 5)}"
    end

    test "three seats colliding on one lane key: all converge on a verifying pair (lens-3)" do
      port = free_port()
      on_exit(fn -> rm_seat(port) end)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        {:ok, cert, key} = ensure_dev_cert(port)

        # Three booting seats collide on the SAME lane key (port+pid+lane
        # collision: e.g. SMALT_TLS_LANE unset, same port, same OS pid — the
        # fallback key is VM-global). :global.trans serializes them on
        # {__MODULE__, cert}; every seat observes either the cached pair or a
        # full regenerate, never a skew.
        seats =
          for n <- 1..3 do
            Task.async(fn ->
              # corrupt seed forces each seat down the regenerate path
              if n == 1, do: File.write!(cert, "trunc")
              Smalt.TLS.ensure_dev_cert(port)
            end)
          end

        results = Enum.map(seats, &Task.await(&1, 60_000))
        assert Enum.all?(results, &match?({:ok, ^cert, ^key}, &1))

        [{_, der, :not_encrypted}] = cert |> File.read!() |> :public_key.pem_decode()

        [{:RSAPrivateKey, kder, :not_encrypted}] =
          key |> File.read!() |> :public_key.pem_decode()

        priv = :public_key.der_decode(:RSAPrivateKey, kder)
        pubkey = {:RSAPublicKey, elem(priv, 2), elem(priv, 3)}
        assert :public_key.pkix_verify(der, pubkey)

        # fallback-uniqueness probe: distinct lane keys never collide on one
        # file, and the pid fallback is stable within the VM (same key for all
        # callers — the seat identity the lock is keyed on)
        {c1, k1} = dev_cert_paths("lane-a")
        {c2, k2} = dev_cert_paths("lane-b")
        {c3, k3} = dev_cert_paths()
        assert c1 != c2 and k1 != k2 and c1 != c3 and c2 != c3 and k1 != k3 and k2 != k3
        assert {dev_cert_paths(), dev_cert_paths()} == {{c3, k3}, {c3, k3}}
      end)
    end

    test "regenerate twice concurrently: single winner, published pair always consistent" do
      port = free_port()
      on_exit(fn -> rm_seat(port) end)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        {:ok, cert, key} = ensure_dev_cert(port)

        tasks =
          for _ <- 1..8 do
            Task.async(fn -> Smalt.TLS.ensure_dev_cert(port) end)
          end

        results = Enum.map(tasks, &Task.await(&1, 30_000))
        assert Enum.all?(results, &match?({:ok, ^cert, ^key}, &1))

        # whatever pair landed must verify: cert signed by the paired key
        [{_, der, :not_encrypted}] = cert |> File.read!() |> :public_key.pem_decode()
        [{:RSAPrivateKey, kder, :not_encrypted}] = key |> File.read!() |> :public_key.pem_decode()
        priv = :public_key.der_decode(:RSAPrivateKey, kder)
        pubkey = {:RSAPublicKey, elem(priv, 2), elem(priv, 3)}
        assert :public_key.pkix_verify(der, pubkey)

        # no temp files left behind (this seat only — other seats in the
        # shared dir belong to other tests/runs and must not fail us)
        leftovers =
          Path.wildcard(Path.join(seat_dir(), "dev-cert-#{port}.pem.tmp-*")) ++
            Path.wildcard(Path.join(seat_dir(), "dev-key-#{port}.pem.tmp-*"))

        assert leftovers == []
      end)
    end

    test "regenerate during active serving: no listener drop" do
      port = free_port()
      on_exit(fn -> rm_seat(port) end)
      on_exit(fn -> rm_seat("rotate-check-#{:os.getpid()}") end)

      with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
        {:ok, cert, key} = ensure_dev_cert(port)
        start_supervised!({Bandit, bandit_opts(__MODULE__, port)})

        assert {:ok, _} = :ssl.connect(~c"localhost", port, verify: :verify_none, active: false)

        # regenerate on disk while serving — the listener must not drop
        assert {:ok, rc, rk} = Smalt.TLS.ensure_dev_cert("rotate-check-#{:os.getpid()}")
        assert rc != cert and rk != key

        # rotation semantics pin: the running listener keeps serving the cert
        # it was booted with (cert material is read once at listener start) —
        # a rotated cert on disk does NOT hot-reload; a listener restart is
        # required to pick it up.
        old_serial = cert_serial(cert)
        assert :ok = Smalt.TLS.write_dev_cert(cert, key)

        assert {:ok, sock} =
                 :ssl.connect(~c"localhost", port, verify: :verify_none, active: false)

        {:ok, peer_der} = :ssl.peercert(sock)
        :ok = :ssl.close(sock)
        assert cert_serial_der(peer_der) == old_serial
        assert :ok = Smalt.TLS.write_dev_cert(cert, key)

        # old listener still serves (cert is read at listener start)
        assert {:ok, sock} =
                 :ssl.connect(~c"localhost", port, verify: :verify_none, active: false)

        :ok = :ssl.close(sock)
      end)
    end
  end

  test "Bandit https boot + :ssl connect + :httpc round-trip" do
    port = free_port()
    on_exit(fn -> rm_seat(port) end)

    with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
      opts = bandit_opts(__MODULE__, port)

      start_supervised!({Bandit, opts})

      # This OTP's ssl client rejects any self-signed peer cert as anchor
      # (selfsigned_peer) unless a verify_fun accepts it — mirrors a local dev
      # client pinning the self-signed dev cert.
      verify_fun = fn
        _cert, {:bad_cert, :selfsigned_peer}, acc -> {:valid, acc}
        _cert, {:extension, _}, acc -> {:unknown, acc}
        _cert, {:valid, _}, acc -> {:valid, acc}
      end

      {:ok, ssl_sock} =
        :ssl.connect(~c"localhost", port,
          verify: :verify_peer,
          active: false,
          cacertfile:
            String.to_charlist(
              Path.expand(bandit_opts(__MODULE__, port)[:certfile] |> List.to_string())
            ),
          depth: 1,
          server_name_indication: ~c"localhost",
          verify_fun: {verify_fun, :ok}
        )

      :ok = :ssl.send(ssl_sock, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert {:ok, data} = :ssl.recv(ssl_sock, 15, 5_000)
      assert to_string(data) =~ "HTTP/1.1 200 OK"

      rest = recv_all(ssl_sock, to_string(data))
      assert rest =~ "tls-ok"
      :ok = :ssl.close(ssl_sock)

      :inets.start()
      :ssl.start()

      assert {:ok, {{_, 200, _}, _, body}} =
               :httpc.request(
                 :get,
                 {~c"https://localhost:#{port}/", []},
                 [ssl: [verify: :verify_none]],
                 []
               )

      assert to_string(body) == "tls-ok"
    end)
  after
  end

  # -- fault-injected reader (deterministic M2 kill, lens-2) --------------------

  # OTP 28 removed fun/MFA tracers from erlang:trace/3 (both raise badarg on
  # this OTP), so the planned "pause the writer mid-publish" interpose is not
  # implementable here. Deterministic replacement: trace-collect the publish's
  # file ops to a tracer PROCESS (events are guaranteed-sent before the writer
  # returns from its traced section) and assert the publish mechanism — writes
  # go only to .tmp-* paths, then two renames onto the live paths. Under the
  # in-place-write mutant (M2) the live cert path is written directly with zero
  # renames, so the mutant is killed with certainty rather than by racing a
  # µs-scale torn-read window.
  defp collect_publish_ops(writer_fn) do
    parent = self()
    tracer = spawn(fn -> publish_ops_loop(parent, []) end)

    :erlang.trace_pattern({:file, :_, :_}, [], [:local])
    :erlang.trace_pattern({:prim_file, :_, :_}, [], [:local])

    task =
      Task.async(fn ->
        :erlang.trace(self(), true, [:call, {:tracer, tracer}])
        result = writer_fn.()
        :erlang.trace(self(), false, [:call])
        result
      end)

    result = Task.await(task, 60_000)
    # trace events were all sent before the writer returned; allow in-flight
    # delivery to the tracer mailbox to drain before requesting the log.
    Process.sleep(200)
    send(tracer, {:ops, parent})

    ops =
      receive do
        {:ops, ops} -> ops
      after
        5_000 -> []
      end

    {result, ops}
  end

  defp publish_ops_loop(parent, acc) do
    receive do
      {:trace, _pid, :call, mfa} -> publish_ops_loop(parent, [mfa | acc])
      {:ops, ^parent} -> send(parent, {:ops, Enum.reverse(acc)})
    end
  end

  defp live_pem_path?(path, live_path) do
    is_binary(path) and Path.expand(path) == Path.expand(live_path)
  end

  test "publish mechanism: writes target only tmp paths, then rename (deterministic M2 kill)" do
    port = free_port()
    on_exit(fn -> rm_seat(port) end)

    with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
      {:ok, cert, key} = ensure_dev_cert(port)

      {:ok, ops} =
        collect_publish_ops(fn -> :ok = Smalt.TLS.write_dev_cert(cert, key) end)

      writes = for {:file, :write_file, [path, _data, _opts]} <- ops, do: path
      renames = for {:file, :rename, [from, to]} <- ops, do: {from, to}

      # no in-place write ever touches the live cert/key paths — under the
      # in-place mutant these hold the live paths and renames are empty.
      assert Enum.all?(writes, fn w ->
               not live_pem_path?(w, cert) and not live_pem_path?(w, key)
             end),
             "in-place write on live path: #{inspect(writes)}"

      assert Enum.any?(renames, fn {_f, t} -> live_pem_path?(t, cert) end),
             "no rename onto live cert path: #{inspect(ops)}"

      assert Enum.any?(renames, fn {_f, t} -> live_pem_path?(t, key) end)
      assert Enum.all?(List.wrap(ops), fn op -> match?({:file, _, _}, op) end)
    end)
  after
  end

  test "boot-time read racing a publisher: locked reader sees a verifying pair" do
    port = free_port()
    on_exit(fn -> rm_seat(port) end)

    with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
      {:ok, cert, key} = ensure_dev_cert(port)

      writer =
        Task.async(fn ->
          # corrupt seed forces the regenerate path, so the writer holds the
          # same-seat :global lock across the whole publish
          File.write!(cert, "trunc")
          Smalt.TLS.ensure_dev_cert(port)
        end)

      # reader boots concurrently: under the shared lock it either reads the
      # pre-publish state (corrupt -> regenerates under the same lock) or the
      # complete post-publish state — never a half-applied pair.
      reader =
        Task.async(fn ->
          for _ <- 1..5 do
            assert {:ok, ^cert, ^key} = Smalt.TLS.ensure_dev_cert(port)
            [{_, der, :not_encrypted}] = cert |> File.read!() |> :public_key.pem_decode()

            [{:RSAPrivateKey, kder, :not_encrypted}] =
              key |> File.read!() |> :public_key.pem_decode()

            priv = :public_key.der_decode(:RSAPrivateKey, kder)
            pubkey = {:RSAPublicKey, elem(priv, 2), elem(priv, 3)}
            assert :public_key.pkix_verify(der, pubkey)
          end

          :reader_ok
        end)

      assert {:ok, ^cert, ^key} = Task.await(writer, 60_000)
      assert :reader_ok = Task.await(reader, 60_000)
    end)
  after
  end

  test "skewed pair on disk (cert_n + key_n-1) is detected and regenerated, not served" do
    port = free_port()
    on_exit(fn -> rm_seat(port) end)

    with_config([tls: :auto, tls_certfile: nil, tls_keyfile: nil], fn ->
      {:ok, cert, key} = ensure_dev_cert(port)
      {:ok, other_cert_pem, _} = generate_dev_cert_pem()
      # skew: whole parseable cert from a DIFFERENT key
      File.write!(cert, other_cert_pem)
      assert {:ok, ^cert, ^key} = ensure_dev_cert(port)

      [{_, der, :not_encrypted}] = cert |> File.read!() |> :public_key.pem_decode()

      [{:RSAPrivateKey, kder, :not_encrypted}] =
        key |> File.read!() |> :public_key.pem_decode()

      priv = :public_key.der_decode(:RSAPrivateKey, kder)
      pubkey = {:RSAPublicKey, elem(priv, 2), elem(priv, 3)}
      assert :public_key.pkix_verify(der, pubkey)
    end)
  after
  end

  test "mismatched explicit certfile/keyfile pair is a typed refusal, not an :ssl crash" do
    {:ok, c1, k1} = generate_dev_cert_pem()
    {:ok, c2, _k2} = generate_dev_cert_pem()

    {cert, key} =
      {Path.expand("tmp/dev-certs/explicit-a-#{:os.getpid()}.pem"),
       Path.expand("tmp/dev-certs/explicit-a-key-#{:os.getpid()}.pem")}

    File.mkdir_p(Path.dirname(cert))
    File.write!(cert, c1)
    File.write!(key, k1)

    with_config([tls_certfile: cert, tls_keyfile: key, tls: :delete], fn ->
      assert {:ok, ^cert, ^key} = ensure_dev_cert()

      # swap in a cert from a different pair
      File.write!(cert, c2)
      assert {:error, {:corrupt_certfile, ^cert, :cert_key_mismatch}} = ensure_dev_cert()
    end)
  after
    pid = :os.getpid()
    File.rm(Path.expand("tmp/dev-certs/explicit-a-#{pid}.pem"))
    File.rm(Path.expand("tmp/dev-certs/explicit-a-key-#{pid}.pem"))
  end

  test "SMALT_TLS_CERTFILE/KEYFILE env pair wins over config certfiles (R100/D64)" do
    # in-repo dev fallback pair at the canonical .smalt/tls path
    dev_cert = Path.expand(".smalt/tls/dev-cert.pem")
    dev_key = Path.expand(".smalt/tls/dev-key.pem")
    {:ok, dc, dk} = generate_dev_cert_pem()
    File.mkdir_p(Path.dirname(dev_cert))
    File.write!(dev_cert, dc)
    File.write!(dev_key, dk)

    # temp env pair
    {:ok, ec, ek} = generate_dev_cert_pem()
    env_cert = Path.expand("tmp/dev-certs/env-pair-cert-#{:os.getpid()}.pem")
    env_key = Path.expand("tmp/dev-certs/env-pair-key-#{:os.getpid()}.pem")
    File.mkdir_p(Path.dirname(env_cert))
    File.write!(env_cert, ec)
    File.write!(env_key, ek)

    System.put_env("SMALT_TLS_CERTFILE", env_cert)
    System.put_env("SMALT_TLS_KEYFILE", env_key)

    try do
      # env pair takes precedence over the in-repo config path
      with_config([tls_certfile: dev_cert, tls_keyfile: dev_key, tls: :delete], fn ->
        assert {:ok, ^env_cert, ^env_key} = ensure_dev_cert()

        # env removed -> falls back to the dev/config path
        System.delete_env("SMALT_TLS_CERTFILE")
        System.delete_env("SMALT_TLS_KEYFILE")
        assert {:ok, ^dev_cert, ^dev_key} = ensure_dev_cert()
      end)
    after
      System.delete_env("SMALT_TLS_CERTFILE")
      System.delete_env("SMALT_TLS_KEYFILE")
      File.rm(env_cert)
      File.rm(env_key)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp cert_serial(path) do
    [{_, der, :not_encrypted}] = path |> File.read!() |> :public_key.pem_decode()
    cert_serial_der(der)
  end

  defp cert_serial_der(der) do
    elem(:public_key.der_decode(:Certificate, der), 1) |> elem(2)
  end

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
    [{:AttributeTypeAndValue, @cn_oid, {:printableString, cn}}] = rdn
    cn
  end

  defp extract_san(otp) do
    exts = elem(elem(otp, 1), 10)

    {:Extension, {2, 5, 29, 17}, _, der} =
      Enum.find(exts, &match?({:Extension, {2, 5, 29, 17}, _, _}, &1))

    Enum.map(der, fn
      {:dNSName, name} -> {2, name}
      {:iPAddress, ip} -> {4, ip}
      other -> other
    end)
  end

  # R156: mint a real CA-chained pair (CA:TRUE root + CA-signed leaf), the
  # gen_dev_cert.sh shape. The leaf's signature is made by the CA key, not the
  # leaf key — the pairing check must be an SPKI identity match, not a
  # self-signature verify (which rejected every CA-chained leaf).
  defp mint_ca_chained_pair(dir) do
    File.mkdir_p!(dir)
    ca_cert = Path.join(dir, "ca-cert.pem")
    ca_key = Path.join(dir, "ca-key.pem")
    leaf_cert = Path.join(dir, "dev-cert.pem")
    leaf_key = Path.join(dir, "dev-key.pem")

    System.cmd("openssl", [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-days",
      "30",
      "-nodes",
      "-keyout",
      ca_key,
      "-out",
      ca_cert,
      "-subj",
      "/CN=smalt-test-ca",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign"
    ])

    csr = Path.join(dir, "dev-csr.pem")

    System.cmd("openssl", [
      "req",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-nodes",
      "-keyout",
      leaf_key,
      "-out",
      csr,
      "-subj",
      "/CN=localhost"
    ])

    System.cmd("openssl", [
      "x509",
      "-req",
      "-sha256",
      "-days",
      "30",
      "-in",
      csr,
      "-CA",
      ca_cert,
      "-CAkey",
      ca_key,
      "-CAcreateserial",
      "-out",
      leaf_cert
    ])

    {leaf_cert, leaf_key}
  end

  test "CA-chained explicit pair validates (R156: pairing is SPKI match, not self-signature)" do
    dir = Path.expand("tmp/dev-certs/r156-ca-#{:os.getpid()}")
    {cert, key} = mint_ca_chained_pair(dir)

    with_config([tls_certfile: cert, tls_keyfile: key, tls: :delete], fn ->
      assert {:ok, ^cert, ^key} = ensure_dev_cert()

      # a genuinely mismatched pair (CA cert + leaf key) still refuses
      File.cp!(Path.join(dir, "ca-cert.pem"), cert)
      assert {:error, {:corrupt_certfile, ^cert, :cert_key_mismatch}} = ensure_dev_cert()
    end)
  after
    File.rm_rf(Path.expand("tmp/dev-certs/r156-ca-#{:os.getpid()}"))
  end
end
