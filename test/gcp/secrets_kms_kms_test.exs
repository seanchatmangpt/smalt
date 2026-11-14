defmodule Smalt.GCP.SecretsKmsKmsTest do
  use ExUnit.Case, async: true
  alias Smalt.GCP.KMS

  @ring "/v1/projects/p/locations/global/keyRings/r"

  setup do
    {:ok, pid} = KMS.start_link(name: nil)
    {200, _} = KMS.handle(pid, "POST", "/v1/projects/p/locations/global/keyRings", %{"keyRingId" => "r"})
    {:ok, pid: pid}
  end

  test "encrypt/decrypt survives rotation; tamper and AAD mismatch fail", %{pid: k} do
    assert {200, %{"purpose" => "ENCRYPT_DECRYPT"}} =
             KMS.handle(k, "POST", @ring <> "/cryptoKeys", %{"cryptoKeyId" => "a"}, %{"rotationPeriod" => "86400s"})

    aad = Base.encode64("ctx")
    pt = Base.encode64("hello kms")
    assert {200, %{"ciphertext" => ct}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:encrypt", %{}, %{"plaintext" => pt, "additionalAuthenticatedData" => aad})
    assert {200, %{"plaintext" => ^pt}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:decrypt", %{}, %{"ciphertext" => ct, "additionalAuthenticatedData" => aad})
    assert {400, _} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:decrypt", %{}, %{"ciphertext" => ct})

    raw = Base.decode64!(ct)
    bad = Base.encode64(binary_part(raw, 0, byte_size(raw) - 1) <> <<:binary.last(raw) |> Bitwise.bxor(1)>>)
    assert {400, _} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:decrypt", %{}, %{"ciphertext" => bad, "additionalAuthenticatedData" => aad})

    assert {200, %{"name" => v2}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a/cryptoKeyVersions")
    assert String.ends_with?(v2, "/2")
    assert {200, %{"primary" => %{"name" => p}}} = KMS.handle(k, "GET", @ring <> "/cryptoKeys/a")
    assert String.ends_with?(p, "/2")
    # old ciphertext still decrypts; new ciphertext differs in version header
    assert {200, %{"plaintext" => ^pt}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:decrypt", %{}, %{"ciphertext" => ct, "additionalAuthenticatedData" => aad})
    assert {200, %{"ciphertext" => ct2}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:encrypt", %{}, %{"plaintext" => pt})
    assert <<2::32, _::binary>> = Base.decode64!(ct2)

    # destroyed v1 can no longer decrypt
    assert {200, %{"state" => "DESTROYED"}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a/cryptoKeyVersions/1:destroy")
    assert {400, _} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/a:decrypt", %{}, %{"ciphertext" => ct, "additionalAuthenticatedData" => aad})
  end

  test "asymmetric sign verifies with returned PEM public key", %{pid: k} do
    assert {200, _} = KMS.handle(k, "POST", @ring <> "/cryptoKeys", %{"cryptoKeyId" => "s"}, %{"purpose" => "ASYMMETRIC_SIGN"})
    msg = "sign me"
    digest = :crypto.hash(:sha256, msg)
    assert {200, %{"signature" => sig}} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/s/cryptoKeyVersions/1:asymmetricSign", %{}, %{"digest" => %{"sha256" => Base.encode64(digest)}})
    assert {200, %{"pem" => pem}} = KMS.handle(k, "GET", @ring <> "/cryptoKeys/s/cryptoKeyVersions/1/publicKey")
    [entry] = :public_key.pem_decode(pem)
    pub = :public_key.pem_entry_decode(entry)
    assert :public_key.verify(msg, :sha256, Base.decode64!(sig), pub)
    refute :public_key.verify("other", :sha256, Base.decode64!(sig), pub)

    # purpose enforcement
    assert {400, _} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/s:encrypt", %{}, %{"plaintext" => "AA=="})
    assert {400, _} = KMS.handle(k, "POST", @ring <> "/cryptoKeys/s/cryptoKeyVersions/1:asymmetricSign", %{}, %{"digest" => %{"sha256" => "AA=="}})
  end
end
