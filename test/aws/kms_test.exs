defmodule Smalt.AWS.KMSTest do
  use ExUnit.Case, async: true
  alias Smalt.AWS.KMS

  defp call(op, p), do: KMS.dispatch(op, p)
  defp create(spec \\ "SYMMETRIC_DEFAULT"), do: call("CreateKey", %{"KeySpec" => spec}) |> elem(1) |> get_in(["KeyMetadata", "KeyId"])

  test "AES-GCM encrypt/decrypt roundtrip; context and tamper are enforced" do
    id = create()
    pt = Base.encode64("top secret")
    {200, %{"CiphertextBlob" => blob}} = call("Encrypt", %{"KeyId" => id, "Plaintext" => pt, "EncryptionContext" => %{"a" => "b"}})
    refute blob =~ "top secret"
    assert {200, %{"Plaintext" => ^pt}} = call("Decrypt", %{"CiphertextBlob" => blob, "EncryptionContext" => %{"a" => "b"}})
    assert {400, %{"__type" => "InvalidCiphertextException"}} = call("Decrypt", %{"CiphertextBlob" => blob, "EncryptionContext" => %{"a" => "c"}})
    raw = Base.decode64!(blob)
    flipped = binary_part(raw, 0, byte_size(raw) - 1) <> <<Bitwise.bxor(:binary.last(raw), 1)>>
    assert {400, %{"__type" => "InvalidCiphertextException"}} = call("Decrypt", %{"CiphertextBlob" => Base.encode64(flipped), "EncryptionContext" => %{"a" => "b"}})
  end

  test "rotation: old ciphertext still decrypts, new ciphertext uses new version" do
    id = create()
    pt = Base.encode64("v1 data")
    {200, %{"CiphertextBlob" => old}} = call("Encrypt", %{"KeyId" => id, "Plaintext" => pt})
    assert {200, _} = call("RotateKeyOnDemand", %{"KeyId" => id})
    {200, %{"CiphertextBlob" => new}} = call("Encrypt", %{"KeyId" => id, "Plaintext" => pt})
    assert <<_::binary-size(42), 1::16, _::binary>> = Base.decode64!(old)
    assert <<_::binary-size(42), 2::16, _::binary>> = Base.decode64!(new)
    assert {200, %{"Plaintext" => ^pt}} = call("Decrypt", %{"CiphertextBlob" => old})
    assert {200, %{"Plaintext" => ^pt}} = call("Decrypt", %{"CiphertextBlob" => new})
    assert {200, %{"KeyMetadata" => %{"CurrentKeyVersion" => 2}}} = call("DescribeKey", %{"KeyId" => id})
    assert {200, _} = call("EnableKeyRotation", %{"KeyId" => id})
    assert {200, %{"KeyMetadata" => %{"KeyRotationEnabled" => true}}} = call("DescribeKey", %{"KeyId" => id})
  end

  test "GenerateDataKey plaintext decrypts from its blob; disabled key refuses" do
    id = create()
    {200, %{"Plaintext" => dk, "CiphertextBlob" => blob}} = call("GenerateDataKey", %{"KeyId" => id, "KeySpec" => "AES_256"})
    assert byte_size(Base.decode64!(dk)) == 32
    assert {200, %{"Plaintext" => ^dk}} = call("Decrypt", %{"CiphertextBlob" => blob})
    call("DisableKey", %{"KeyId" => id})
    assert {400, %{"__type" => "DisabledException"}} = call("Encrypt", %{"KeyId" => id, "Plaintext" => dk})
  end

  test "ECDSA sign/verify, RAW and DIGEST, tamper detected, public key verifies externally" do
    id = create("ECC_NIST_P256")
    msg = Base.encode64("sign me")
    base = %{"KeyId" => id, "SigningAlgorithm" => "ECDSA_SHA_256"}
    {200, %{"Signature" => sig}} = call("Sign", Map.merge(base, %{"Message" => msg}))
    assert {200, %{"SignatureValid" => true}} = call("Verify", Map.merge(base, %{"Message" => msg, "Signature" => sig}))
    assert {400, %{"__type" => "KMSInvalidSignatureException"}} = call("Verify", Map.merge(base, %{"Message" => Base.encode64("other"), "Signature" => sig}))
    digest = Base.encode64(:crypto.hash(:sha256, "sign me"))
    assert {200, %{"SignatureValid" => true}} = call("Verify", Map.merge(base, %{"Message" => digest, "MessageType" => "DIGEST", "Signature" => sig}))
    {200, %{"PublicKey" => pub}} = call("GetPublicKey", %{"KeyId" => id})
    assert :crypto.verify(:ecdsa, :sha256, "sign me", Base.decode64!(sig), [Base.decode64!(pub), :secp256r1])
    assert {400, %{"__type" => "InvalidKeyUsageException"}} = call("Encrypt", %{"KeyId" => id, "Plaintext" => msg})
  end

  test "unknown key, unsupported spec" do
    assert {400, %{"__type" => "NotFoundException"}} = call("DescribeKey", %{"KeyId" => "00000000-0000-4000-8000-000000000000"})
    assert {400, %{"__type" => "UnsupportedOperationException"}} = call("CreateKey", %{"KeySpec" => "RSA_2048"})
  end
end
