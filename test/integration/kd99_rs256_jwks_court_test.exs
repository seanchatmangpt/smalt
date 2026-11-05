defmodule Smalt.Test.Integration.Kd99Rs256JwksCourtTest do
  @moduledoc """
  KD-99 close-condition court (canonical row:
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) — the STS/bearer RS256+JWKS
  falsifier as a durable in-repo court over the real auth face.

  Falsifier (verbatim from the row): "identity-SDK probe fetches JWKS,
  validates RS256 signature+kid (true; tampered control false)".

  Chicago: the real ArmGateway.Router pipeline (mint + JWKS + auth plug),
  the real Bearer verify path, real RSA math over the SERVED JWK. No mocks;
  the only mutation is the tampered control. No sleeps. Note: the ARM HTTP
  listener is not dialable under plain `mix test` in this window (witnessed:
  existing signins_log_test 3/5 econnrefused — pre-existing), so the court
  dispatches the real router in-process (issuer_config pattern).
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @tenant "organizations"

  # Mint a bearer over the real Router pipeline (STS bootstrap endpoint).
  defp mint do
    conn =
      :post
      |> conn("/#{@tenant}/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "kd99-court",
        "client_secret" => "x"
      })
      |> Router.call([])

    assert conn.status == 200
    %{"access_token" => token} = Jason.decode!(conn.resp_body)
    token
  end

  # Fetch the JWKS over the same real Router pipeline.
  defp fetch_jwks do
    conn =
      :get
      |> conn("/#{@tenant}/discovery/v2.0/keys")
      |> Router.call([])

    assert conn.status == 200
    %{"keys" => [jwk]} = Jason.decode!(conn.resp_body)
    jwk
  end

  defp jwt_parts(token) do
    [hdr_b64, pld_b64, sig_b64] = String.split(token, ".", parts: 3)

    {:ok, hdr_json} = Base.url_decode64(hdr_b64, padding: false)
    header = Jason.decode!(hdr_json)

    {hdr_b64, pld_b64, sig_b64, header}
  end

  defp decode_uint(b64) do
    {:ok, bin} = Base.url_decode64(b64, padding: false)
    :crypto.bytes_to_integer(bin)
  end

  # RFC 7638 thumbprint recomputed from the SERVED JWK members only.
  defp thumbprint_from_served(jwk) do
    canonical = ~s({"e":"#{jwk["e"]}","kty":"#{jwk["kty"]}","n":"#{jwk["n"]}"})

    Base.url_encode64(:crypto.hash(:sha256, canonical), padding: false)
  end

  defp rsa_pub_from_served(jwk) do
    n = decode_uint(jwk["n"])
    e = decode_uint(jwk["e"])

    :public_key.der_decode(
      :RSAPublicKey,
      :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, n, e})
    )
  end

  # Tampered control WITHOUT breaking base64url decodability: flip bit 0 of
  # the last decoded payload byte, re-encode (same header, same signature).
  defp mutate_payload(pld_b64) do
    {:ok, bin} = Base.url_decode64(pld_b64, padding: false)
    size = byte_size(bin) - 1
    <<prefix::binary-size(size), last>> = bin

    Base.url_encode64(<<prefix::binary, Bitwise.bxor(last, 1)>>, padding: false)
  end

  defp rebuild_token(hdr_b64, new_payload_b64, sig_b64) do
    Enum.join([hdr_b64, new_payload_b64, sig_b64], ".")
  end

  # -- KD-99 falsifier legs -------------------------------------------------------

  test "mint over the real Router answers 200 with an RS256 kid-bearing token" do
    token = mint()
    {hdr_b64, pld_b64, sig_b64, header} = jwt_parts(token)

    assert header["alg"] == "RS256"
    assert is_binary(header["kid"]) and header["kid"] != ""
    assert header["kid"] == Smalt.Auth.StsKey.kid()

    # Well-formedness: three splittable JWT segments, real payload claims.
    assert byte_size(sig_b64) > 100
    assert is_map(Jason.decode!(elem(Base.url_decode64(pld_b64, padding: false), 1)))
  end

  test "JWKS endpoint serves the emulator RSA public key (kty/alg/use/kid)" do
    jwk = fetch_jwks()

    assert jwk["kty"] == "RSA"
    assert jwk["alg"] == "RS256"
    assert jwk["use"] == "sig"
    assert jwk["kid"] == Smalt.Auth.StsKey.kid()
    assert byte_size(jwk["n"]) > 200
  end

  test "served kid byte-equals the RFC 7638 thumbprint of the served JWK" do
    jwk = fetch_jwks()
    assert jwk["kid"] == thumbprint_from_served(jwk)
  end

  test "RS256 signature verifies against the served JWK (tampered control false)" do
    token = mint()
    {hdr_b64, pld_b64, sig_b64, _header} = jwt_parts(token)

    jwk = fetch_jwks()
    rsa_pub = rsa_pub_from_served(jwk)

    {:ok, sig} = Base.url_decode64(sig_b64, padding: false)
    signing_input = hdr_b64 <> "." <> pld_b64

    assert :public_key.verify(signing_input, :sha256, sig, rsa_pub)

    # Tampered control: one flipped payload byte -> verify MUST go false.
    tampered = mutate_payload(pld_b64)
    refute :public_key.verify(hdr_b64 <> "." <> tampered, :sha256, sig, rsa_pub)
  end

  test "auth face: Bearer.verify_bearer admits the minted token, refuses the tampered one" do
    token = mint()
    {hdr_b64, pld_b64, sig_b64, _header} = jwt_parts(token)
    assert :ok = Smalt.Auth.Bearer.verify_bearer(bearer_conn(token))

    # Tampered control on the SAME verify face: one flipped payload byte
    # (same signature, same header) -> refused.
    tampered_token = rebuild_token(hdr_b64, mutate_payload(pld_b64), sig_b64)

    assert {:refuse, code, reason} =
             Smalt.Auth.Bearer.verify_bearer(bearer_conn(tampered_token))

    assert is_binary(code) and is_binary(reason)
  end

  # Mint and verify both ride the same default request-derived authority
  # (Plug.Test conn host), so the Bearer issuer law admits the mint.
  defp bearer_conn(token) do
    :get
    |> conn("/subscriptions", "")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end
end
