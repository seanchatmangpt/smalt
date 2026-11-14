defmodule Smalt.AWS.KMS do
  @moduledoc """
  KMS (JSON 1.1, `TrentService.<Op>`) with real cryptography (AS2).

  Keys live in `:smalt_cosmos_docs` under `{:aws_kms, key_id}`; every mutation is a
  `Smalt.Store` CAS/insert_new. SYMMETRIC_DEFAULT = AES-256-GCM, 96-bit IV, AAD = canonical
  EncryptionContext. Ciphertext blob = `"SMKMS1" <> key_id(36) <> version::16 <> iv(12) <>
  tag(16) <> ct`, so old key versions stay decryptable after rotation. ECC_NIST_P256 keys sign
  with ECDSA_SHA_256 (RAW or DIGEST message type). Ops: CreateKey, DescribeKey, ListKeys,
  Encrypt, Decrypt, GenerateDataKey, Sign, Verify, GetPublicKey, EnableKeyRotation,
  DisableKeyRotation, RotateKeyOnDemand, DisableKey, EnableKey. UNSUPPORTED: RSA specs, grants,
  aliases, ReEncrypt, key deletion scheduling.
  """
  alias Smalt.Store

  @table :smalt_cosmos_docs
  @magic "SMKMS1"
  @retries 8

  def error(type, msg), do: {400, %{"__type" => type, "message" => msg}}
  defp fail(type, msg), do: throw({:kms, type, msg})

  def dispatch(op, p) when is_binary(op) and is_map(p) do
    run(op, p)
  catch
    {:kms, type, msg} -> error(type, msg)
  end

  defp key_k(id), do: {:aws_kms, id}

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> IO.iodata_to_binary()
  end

  defp resolve_id(ref) when is_binary(ref) do
    ref |> String.split("/") |> List.last()
  end

  defp resolve_id(_), do: fail("ValidationException", "KeyId is required")

  defp fetch(ref) do
    id = resolve_id(ref)

    case Store.get(@table, key_k(id)) do
      {:ok, k} -> k
      :error -> fail("NotFoundException", "Key '#{ref}' does not exist")
    end
  end

  defp enabled!(k), do: if(k.enabled, do: k, else: fail("DisabledException", "#{k.arn} is disabled."))

  defp mutate(id, fun, n \\ @retries)
  defp mutate(_id, _fun, 0), do: fail("KMSInternalException", "contention")

  defp mutate(id, fun, n) do
    {:ok, old} = Store.get(@table, key_k(id))
    new = fun.(old)

    case Store.compare_and_swap(@table, key_k(id), old, new) do
      :ok -> new
      {:error, :conflict} -> mutate(id, fun, n - 1)
    end
  end

  # ---------- ops ----------
  defp run("CreateKey", p) do
    spec = p["KeySpec"] || p["CustomerMasterKeySpec"] || "SYMMETRIC_DEFAULT"
    usage = p["KeyUsage"] || if(spec == "ECC_NIST_P256", do: "SIGN_VERIFY", else: "ENCRYPT_DECRYPT")
    unless spec in ["SYMMETRIC_DEFAULT", "ECC_NIST_P256"], do: fail("UnsupportedOperationException", "UNSUPPORTED: key spec #{spec}")

    unless (spec == "SYMMETRIC_DEFAULT" and usage == "ENCRYPT_DECRYPT") or (spec == "ECC_NIST_P256" and usage == "SIGN_VERIFY"),
      do: fail("ValidationException", "KeyUsage #{usage} is not compatible with KeySpec #{spec}")

    id = uuid()

    k = %{
      id: id,
      arn: "arn:aws:kms:us-east-1:000000000000:key/#{id}",
      spec: spec,
      usage: usage,
      enabled: true,
      rotation: false,
      description: p["Description"] || "",
      created: System.os_time(:second),
      versions: [new_material(spec)]
    }

    :ok = Store.insert_new(@table, key_k(id), k)
    {200, %{"KeyMetadata" => meta(k)}}
  end

  defp run("DescribeKey", p), do: {200, %{"KeyMetadata" => meta(fetch(p["KeyId"]))}}

  defp run("ListKeys", _p) do
    ks = for {{:aws_kms, _}, k} <- :ets.match_object(@table, {{:aws_kms, :_}, :_}), do: %{"KeyId" => k.id, "KeyArn" => k.arn}
    {200, %{"Keys" => Enum.sort_by(ks, & &1["KeyId"]), "Truncated" => false}}
  end

  defp run("Encrypt", p) do
    k = fetch(p["KeyId"]) |> enabled!() |> sym!()
    pt = b64!(p["Plaintext"])
    {200, %{"KeyId" => k.arn, "CiphertextBlob" => Base.encode64(seal(k, pt, p["EncryptionContext"])), "EncryptionAlgorithm" => "SYMMETRIC_DEFAULT"}}
  end

  defp run("Decrypt", p) do
    blob = b64!(p["CiphertextBlob"])
    {id, _v, _iv, _tag, _ct} = parse_blob(blob)
    k = fetch(p["KeyId"] || id) |> enabled!()
    if k.id != id, do: fail("IncorrectKeyException", "The key ID in the request does not identify a CMK that can perform this operation.")
    {200, %{"KeyId" => k.arn, "Plaintext" => Base.encode64(open(k, blob, p["EncryptionContext"])), "EncryptionAlgorithm" => "SYMMETRIC_DEFAULT"}}
  end

  defp run("GenerateDataKey", p) do
    k = fetch(p["KeyId"]) |> enabled!() |> sym!()

    len =
      case {p["KeySpec"], p["NumberOfBytes"]} do
        {"AES_256", _} -> 32
        {"AES_128", _} -> 16
        {nil, n} when is_integer(n) and n in 1..1024 -> n
        _ -> fail("ValidationException", "KeySpec or NumberOfBytes is required")
      end

    dk = :crypto.strong_rand_bytes(len)
    {200, %{"KeyId" => k.arn, "Plaintext" => Base.encode64(dk), "CiphertextBlob" => Base.encode64(seal(k, dk, p["EncryptionContext"]))}}
  end

  defp run("Sign", p) do
    k = fetch(p["KeyId"]) |> enabled!() |> asym!()
    alg!(p)
    {_pub, priv} = cur(k)
    sig = :crypto.sign(:ecdsa, :sha256, msg(p), [priv, :secp256r1])
    {200, %{"KeyId" => k.arn, "Signature" => Base.encode64(sig), "SigningAlgorithm" => "ECDSA_SHA_256"}}
  end

  defp run("Verify", p) do
    k = fetch(p["KeyId"]) |> enabled!() |> asym!()
    alg!(p)
    sig = b64!(p["Signature"])
    m = msg(p)
    # a rotated-out version could have signed: accept any retained version (asymmetric keys do not rotate, one version)
    ok = Enum.any?(k.versions, fn {pub, _} -> :crypto.verify(:ecdsa, :sha256, m, sig, [pub, :secp256r1]) end)
    if ok, do: {200, %{"KeyId" => k.arn, "SignatureValid" => true, "SigningAlgorithm" => "ECDSA_SHA_256"}}, else: error("KMSInvalidSignatureException", "The signature is invalid.")
  end

  defp run("GetPublicKey", p) do
    k = fetch(p["KeyId"]) |> asym!()
    {pub, _} = cur(k)
    {200, %{"KeyId" => k.arn, "PublicKey" => Base.encode64(pub), "KeySpec" => k.spec, "KeyUsage" => k.usage, "SigningAlgorithms" => ["ECDSA_SHA_256"]}}
  end

  defp run("EnableKeyRotation", p), do: set(p, :rotation, true)
  defp run("DisableKeyRotation", p), do: set(p, :rotation, false)
  defp run("DisableKey", p), do: set(p, :enabled, false)
  defp run("EnableKey", p), do: set(p, :enabled, true)

  defp run("RotateKeyOnDemand", p) do
    k = fetch(p["KeyId"]) |> enabled!() |> sym!()
    mutate(k.id, fn o -> %{o | versions: o.versions ++ [new_material(o.spec)]} end)
    {200, %{"KeyId" => k.arn}}
  end

  defp run(op, _), do: error("UnknownOperationException", "Unsupported operation #{op}")

  defp set(p, field, v) do
    k = fetch(p["KeyId"])
    mutate(k.id, &Map.put(&1, field, v))
    {200, %{}}
  end

  # ---------- helpers ----------
  defp new_material("SYMMETRIC_DEFAULT"), do: :crypto.strong_rand_bytes(32)
  defp new_material("ECC_NIST_P256"), do: :crypto.generate_key(:ecdh, :secp256r1)

  defp meta(k) do
    %{
      "KeyId" => k.id,
      "Arn" => k.arn,
      "AWSAccountId" => "000000000000",
      "CreationDate" => k.created * 1.0,
      "Description" => k.description,
      "Enabled" => k.enabled,
      "KeyState" => if(k.enabled, do: "Enabled", else: "Disabled"),
      "KeyUsage" => k.usage,
      "KeySpec" => k.spec,
      "CustomerMasterKeySpec" => k.spec,
      "KeyManager" => "CUSTOMER",
      "Origin" => "AWS_KMS",
      "KeyRotationEnabled" => k.rotation,
      "CurrentKeyVersion" => length(k.versions)
    }
  end

  defp sym!(%{spec: "SYMMETRIC_DEFAULT"} = k), do: k
  defp sym!(_), do: fail("InvalidKeyUsageException", "This operation requires a symmetric ENCRYPT_DECRYPT key.")
  defp asym!(%{spec: "ECC_NIST_P256"} = k), do: k
  defp asym!(_), do: fail("InvalidKeyUsageException", "This operation requires a SIGN_VERIFY key.")

  defp alg!(p), do: if(p["SigningAlgorithm"] == "ECDSA_SHA_256", do: :ok, else: fail("ValidationException", "SigningAlgorithm must be ECDSA_SHA_256"))

  defp msg(p) do
    m = b64!(p["Message"])
    if p["MessageType"] == "DIGEST", do: {:digest, m}, else: m
  end

  defp cur(k), do: List.last(k.versions)

  defp b64!(s) when is_binary(s) do
    case Base.decode64(s) do
      {:ok, b} -> b
      :error -> fail("ValidationException", "Invalid base64")
    end
  end

  defp b64!(_), do: fail("ValidationException", "Missing required blob parameter")

  defp aad(nil), do: ""
  defp aad(ctx) when is_map(ctx), do: ctx |> Enum.sort() |> Enum.map_join("\0", fn {k, v} -> "#{k}\0#{v}" end)

  defp seal(k, pt, ctx) do
    v = length(k.versions)
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, Enum.at(k.versions, v - 1), iv, pt, aad(ctx), 16, true)
    @magic <> k.id <> <<v::16>> <> iv <> tag <> ct
  end

  defp parse_blob(<<@magic, id::binary-size(36), v::16, iv::binary-size(12), tag::binary-size(16), ct::binary>>), do: {id, v, iv, tag, ct}
  defp parse_blob(_), do: fail("InvalidCiphertextException", "")

  defp open(k, blob, ctx) do
    {_id, v, iv, tag, ct} = parse_blob(blob)
    mat = Enum.at(k.versions, v - 1) || fail("InvalidCiphertextException", "")

    case :crypto.crypto_one_time_aead(:aes_256_gcm, mat, iv, ct, aad(ctx), tag, false) do
      :error -> fail("InvalidCiphertextException", "")
      pt -> pt
    end
  end
end
