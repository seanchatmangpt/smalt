defmodule PopcornDemo.LiveKeyopsTest do
  @moduledoc """
  Chicago-school test for the W4-4 KV key-operations walk: the only
  collaborators are the REAL substrate (data plane 8443 + STS 9443) over real
  `:gen_tcp` sockets. No mocks. Skips loudly only when the substrate is down.

  Under test: the KD-15 challenge handshake against the /keys surface, the
  disjunctive EC-create classification (the live substrate answers a typed
  `400 UnsupportedKeyType` — the HTTP create seam lacks EC dispatch), and the
  real crypto contract: sign -> verify valid:true, tampered -> verify
  valid:false (HTTP 200 KeyVerifyResult, never an error).
  """

  use ExUnit.Case, async: false

  @skip_reason "substrate down — run 9>&- just substrate-up"

  substrate_down? =
    with {:ok, sibling} <-
           :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sibling)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: @skip_reason, else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: #{@skip_reason}")
  end

  @tag skip: @substrate_skip
  test "KD-15 challenge observed: tokenless /keys touch 401s with www-authenticate naming the STS authority" do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, packet: :raw, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /keys/popcorn-key?api-version=7.4 HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\nconnection: close\r\n\r\n"
      )

    {:ok, raw} = read_all(sock)
    :gen_tcp.close(sock)

    assert String.contains?(raw, "401")
    assert String.contains?(raw, "www-authenticate:")

    assert Regex.run(~r/authorization="([^"]+)"/, raw) |> Enum.at(1) =~
             "http://127.0.0.1:9443"
  end

  @tag skip: @substrate_skip
  test "walk is repeatable: two runs return the identical witnessed outcome" do
    a = PopcornDemo.LiveKeyops.run()
    b = PopcornDemo.LiveKeyops.run()
    assert a == b

    case a do
      {:ok, "keyops=OK(ES256:verified)"} -> :ok
      {:skip, "keyops=SKIP(es256:UnsupportedKeyType;rs256-witnessed-ok)"} -> :ok
      other -> flunk("unexpected walk outcome: #{inspect(other)}")
    end
  end

  # Disjunctive: on the CURRENT substrate the HTTP create seam refuses EC
  # (typed 400 UnsupportedKeyType) so the loud SKIP is the correct pass, and
  # the walk must have witnessed RS256 sign -> verify -> tampered for real.
  # When the EC create seam lands this test still passes via the OK branch.
  @tag skip: @substrate_skip
  test "walk outcome is the witnessed disjunction: ES256 OK or loud SKIP with RS256 witnessed" do
    outcome = PopcornDemo.LiveKeyops.run()

    case outcome do
      {:ok, "keyops=OK(ES256:verified)"} -> :ok

      {:skip, "keyops=SKIP(es256:UnsupportedKeyType;rs256-witnessed-ok)"} ->
        :ok

      other ->
        flunk("unexpected walk outcome: #{inspect(other)}")
    end
  end

  @tag skip: @substrate_skip
  test "wire negative: tampered payload verifies to 200 with value:false (RS256 on own RSA key)" do
    # Post-KD-126 the HTTP create seam supports EC and run/0 leaves an EC
    # popcorn-key — this negative witnesses the RSA contract on its OWN key
    # (created over the raw wire), never on run/0's residue.
    token = challenge_token()
    rsa_name = "popcorn-key-rsa-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    create_rsa_key!(token, rsa_name)

    digest = b64url(:crypto.hash(:sha256, "independent-test-payload"))
    sig = sign_named!(token, rsa_name, "RS256", digest)

    assert verify_named?(token, rsa_name, "RS256", digest, sig)
    refute verify_named?(token, rsa_name, "RS256", b64url(:crypto.hash(:sha256, "TAMPERED-payload")), sig)
  end

  @tag skip: @substrate_skip
  test "outcomes are typed: run/0 never returns an untagged value" do
    outcome = PopcornDemo.LiveKeyops.run()

    assert match?({:ok, _}, outcome) or match?({:skip, _}, outcome) or
             match?({:error, _}, outcome)
  end

  # -- independent minimal wire helpers (real transport, no mocks) ----------

  defp challenge_token do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, packet: :raw, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /keys/popcorn-key?api-version=7.4 HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\nconnection: close\r\n\r\n"
      )

    {:ok, raw} = read_all(sock)
    :gen_tcp.close(sock)

    [authority] = Regex.run(~r/authorization="([^"]+)"/, raw, capture: :all_but_first)

    body =
      "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"

    {:ok, sock2} =
      :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, packet: :raw, active: false], 5_000)

    req =
      "POST /organizations/oauth2/v2.0/token HTTP/1.1\r\n" <>
        "host: 127.0.0.1:9443\r\n" <>
        "content-type: application/x-www-form-urlencoded\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock2, req)
    {:ok, raw2} = read_all(sock2)
    :gen_tcp.close(sock2)

    json = raw2 |> String.split("\r\n\r\n", parts: 2) |> List.last()
    %{"access_token" => tok} = Jason.decode!(json)
    tok
  end

  defp sign!(token, alg, digest) do
    sign_named!(token, "popcorn-key", alg, digest)
  end

  defp sign_named!(token, key_name, alg, digest) do
    body = Jason.encode!(%{"alg" => alg, "digest" => digest})

    raw =
      raw_request(
        8443,
        "POST /keys/#{key_name}/sign?api-version=7.4 HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\n" <>
          "authorization: Bearer #{token}\r\n" <>
          "content-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

    assert String.contains?(raw, "200")
    %{"value" => sig} = Jason.decode!(body_of(raw))
    sig
  end

  defp verify_valid?(token, alg, digest, sig) do
    verify_named?(token, "popcorn-key", alg, digest, sig)
  end

  defp verify_named?(token, key_name, alg, digest, sig) do
    body = Jason.encode!(%{"alg" => alg, "digest" => digest, "value" => sig})

    raw =
      raw_request(
        8443,
        "POST /keys/#{key_name}/verify?api-version=7.4 HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\n" <>
          "authorization: Bearer #{token}\r\n" <>
          "content-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

    assert String.contains?(raw, "200")
    %{"value" => valid} = Jason.decode!(body_of(raw))
    valid
  end

  # Creates a real RSA key over the raw wire (the wire contract the negative
  # RS256 contract needs; run/0's popcorn-key is EC post-KD-126).
  defp create_rsa_key!(token, name) do
    body =
      Jason.encode!(%{
        "kty" => "RSA",
        "key_size" => 2048,
        "key_ops" => ["sign", "verify"]
      })

    raw =
      raw_request(
        8443,
        "POST /keys/#{name}/create?api-version=7.4 HTTP/1.1\r\n" <>
          "host: 127.0.0.1:8443\r\n" <>
          "authorization: Bearer #{token}\r\n" <>
          "content-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

    assert String.contains?(raw, "200") or String.contains?(raw, "409")
  end

  defp raw_request(port, req) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    :ok = :gen_tcp.send(sock, req)
    {:ok, raw} = read_all(sock)
    :gen_tcp.close(sock)
    raw
  end

  defp body_of(raw), do: raw |> String.split("\r\n\r\n", parts: 2) |> List.last()

  defp b64url(digest), do: Base.url_encode64(digest, padding: false)

  defp read_all(sock, acc \\ []) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, chunk} -> read_all(sock, [acc | [chunk]])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
    end
  end
end
