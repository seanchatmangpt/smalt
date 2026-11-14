defmodule Smalt.GCP.KMS do
  @moduledoc """
  Cloud KMS REST v1 dialect with real crypto: AES-256-GCM for
  ENCRYPT_DECRYPT keys, ECDSA P-256 for ASYMMETRIC_SIGN keys.
  Ciphertext embeds the key-version number, so decrypt works after rotation.
  `handle/5` maps (method, path, query, body) to `{status, json_map}`.
  """

  @oid {1, 2, 840, 10045, 3, 1, 7}

  def start_link(opts \\ []) do
    init = fn -> %{rings: MapSet.new(), keys: %{}} end

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Agent.start_link(init)
      name -> Agent.start_link(init, name: name)
    end
  end

  def handle(pid, method, path, query \\ %{}, body \\ %{}) do
    segs = path |> String.trim("/") |> String.split("/")
    segs = if hd(segs) == "v1", do: tl(segs), else: segs
    route(pid, method, segs, query, body)
  end

  defp route(pid, "POST", ["projects", p, "locations", l, "keyRings"], q, _) do
    Agent.get_and_update(pid, fn st ->
      id = q["keyRingId"]
      k = {p, l, id}

      cond do
        is_nil(id) -> {err(400, "INVALID_ARGUMENT", "keyRingId required"), st}
        MapSet.member?(st.rings, k) -> {err(409, "ALREADY_EXISTS", "key ring exists"), st}
        true -> {{200, %{"name" => rname(k)}}, %{st | rings: MapSet.put(st.rings, k)}}
      end
    end)
  end

  defp route(pid, "GET", ["projects", p, "locations", l, "keyRings", r], _, _) do
    if Agent.get(pid, &MapSet.member?(&1.rings, {p, l, r})),
      do: {200, %{"name" => rname({p, l, r})}},
      else: err(404, "NOT_FOUND", "key ring not found")
  end

  defp route(pid, "POST", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys"], q, body) do
    Agent.get_and_update(pid, fn st ->
      id = q["cryptoKeyId"]
      purpose = body["purpose"] || "ENCRYPT_DECRYPT"
      k = {p, l, r, id}

      cond do
        not MapSet.member?(st.rings, {p, l, r}) -> {err(404, "NOT_FOUND", "key ring not found"), st}
        is_nil(id) -> {err(400, "INVALID_ARGUMENT", "cryptoKeyId required"), st}
        Map.has_key?(st.keys, k) -> {err(409, "ALREADY_EXISTS", "key exists"), st}
        purpose not in ["ENCRYPT_DECRYPT", "ASYMMETRIC_SIGN"] -> {err(400, "INVALID_ARGUMENT", "unsupported purpose"), st}
        true ->
          rec = %{
            purpose: purpose,
            primary: 1,
            versions: [new_version(purpose, 1)],
            rotation_period: body["rotationPeriod"],
            next_rotation: body["nextRotationTime"]
          }

          {{200, key_json(k, rec)}, put_in(st.keys[k], rec)}
      end
    end)
  end

  defp route(pid, "GET", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys"], _, _) do
    keys =
      Agent.get(pid, & &1.keys)
      |> Enum.filter(fn {{pp, ll, rr, _}, _} -> {pp, ll, rr} == {p, l, r} end)
      |> Enum.sort()
      |> Enum.map(fn {k, rec} -> key_json(k, rec) end)

    {200, %{"cryptoKeys" => keys}}
  end

  defp route(pid, "GET", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys", id], _, _) do
    with_key(pid, {p, l, r, id}, fn k, rec -> {200, key_json(k, rec)} end)
  end

  defp route(pid, "POST", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys", id_act], _, body) do
    case String.split(id_act, ":") do
      [id] -> if id == "", do: err(404, "NOT_FOUND", "no route"), else: err(404, "NOT_FOUND", "no route")
      [id, "encrypt"] -> encrypt(pid, {p, l, r, id}, body)
      [id, "decrypt"] -> decrypt(pid, {p, l, r, id}, body)
      [id, "updatePrimaryVersion"] -> update_primary(pid, {p, l, r, id}, body["cryptoKeyVersionId"])
      _ -> err(404, "NOT_FOUND", "unknown action")
    end
  end

  # rotation: POST .../cryptoKeys/k/cryptoKeyVersions creates a new version and makes it primary
  defp route(pid, "POST", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys", id, "cryptoKeyVersions"], _, _) do
    k = {p, l, r, id}

    Agent.get_and_update(pid, fn st ->
      case Map.get(st.keys, k) do
        nil ->
          {err(404, "NOT_FOUND", "key not found"), st}

        rec ->
          n = length(rec.versions) + 1
          rec = %{rec | versions: rec.versions ++ [new_version(rec.purpose, n)], primary: n}
          {{200, ver_json(k, Enum.at(rec.versions, n - 1))}, put_in(st.keys[k], rec)}
      end
    end)
  end

  defp route(pid, "GET", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys", id, "cryptoKeyVersions"], _, _) do
    with_key(pid, {p, l, r, id}, fn k, rec -> {200, %{"cryptoKeyVersions" => Enum.map(rec.versions, &ver_json(k, &1))}} end)
  end

  defp route(pid, "GET", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys", id, "cryptoKeyVersions", n, "publicKey"], _, _) do
    k = {p, l, r, id}

    with_version(pid, k, n, fn rec, v ->
      if rec.purpose != "ASYMMETRIC_SIGN" do
        err(400, "FAILED_PRECONDITION", "key purpose has no public key")
      else
        pem = pem(v.pub)
        {200, %{"pem" => pem, "algorithm" => "EC_SIGN_P256_SHA256", "name" => vname(k, v.n)}}
      end
    end)
  end

  defp route(pid, "POST", ["projects", p, "locations", l, "keyRings", r, "cryptoKeys", id, "cryptoKeyVersions", n_act], _, body) do
    k = {p, l, r, id}

    case String.split(n_act, ":") do
      [n, "asymmetricSign"] -> sign(pid, k, n, body)
      [n, "destroy"] -> destroy(pid, k, n)
      _ -> err(404, "NOT_FOUND", "unknown action")
    end
  end

  defp route(_, _, _, _, _), do: err(404, "NOT_FOUND", "no such route")

  # -- crypto ---------------------------------------------------------------

  defp new_version("ENCRYPT_DECRYPT", n), do: %{n: n, state: "ENABLED", key: :crypto.strong_rand_bytes(32)}

  defp new_version("ASYMMETRIC_SIGN", n) do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    %{n: n, state: "ENABLED", pub: pub, priv: priv}
  end

  defp encrypt(pid, k, body) do
    with {:ok, pt} <- b64(body["plaintext"]),
         aad <- aad(body) do
      with_key(pid, k, fn _k, rec ->
        v = Enum.at(rec.versions, rec.primary - 1)

        cond do
          rec.purpose != "ENCRYPT_DECRYPT" -> err(400, "FAILED_PRECONDITION", "key purpose is not ENCRYPT_DECRYPT")
          v.state != "ENABLED" -> err(400, "FAILED_PRECONDITION", "primary version not enabled")
          true ->
            iv = :crypto.strong_rand_bytes(12)
            {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, v.key, iv, pt, aad, true)
            blob = <<v.n::32, iv::binary-12, tag::binary-16, ct::binary>>
            {200, %{"name" => vname(k, v.n), "ciphertext" => Base.encode64(blob)}}
        end
      end)
    else
      _ -> err(400, "INVALID_ARGUMENT", "plaintext must be base64")
    end
  end

  defp decrypt(pid, k, body) do
    with {:ok, <<n::32, iv::binary-12, tag::binary-16, ct::binary>>} <- b64(body["ciphertext"]) do
      with_key(pid, k, fn _k, rec ->
        v = Enum.at(rec.versions, n - 1)

        cond do
          rec.purpose != "ENCRYPT_DECRYPT" or is_nil(v) -> err(400, "INVALID_ARGUMENT", "decryption failed: the ciphertext is invalid")
          v.state != "ENABLED" -> err(400, "FAILED_PRECONDITION", "key version #{v.state}")
          true ->
            case :crypto.crypto_one_time_aead(:aes_256_gcm, v.key, iv, ct, aad(body), tag, false) do
              :error -> err(400, "INVALID_ARGUMENT", "decryption failed: the ciphertext is invalid")
              pt -> {200, %{"plaintext" => Base.encode64(pt)}}
            end
        end
      end)
    else
      _ -> err(400, "INVALID_ARGUMENT", "decryption failed: the ciphertext is invalid")
    end
  end

  defp sign(pid, k, n, body) do
    with %{"sha256" => d64} <- body["digest"] || %{},
         {:ok, digest} when byte_size(digest) == 32 <- b64(d64) do
      with_version(pid, k, n, fn rec, v ->
        cond do
          rec.purpose != "ASYMMETRIC_SIGN" -> err(400, "FAILED_PRECONDITION", "key purpose is not ASYMMETRIC_SIGN")
          v.state != "ENABLED" -> err(400, "FAILED_PRECONDITION", "key version #{v.state}")
          true ->
            sig = :crypto.sign(:ecdsa, :sha256, {:digest, digest}, [v.priv, :secp256r1])
            {200, %{"signature" => Base.encode64(sig), "name" => vname(k, v.n)}}
        end
      end)
    else
      _ -> err(400, "INVALID_ARGUMENT", "digest.sha256 must be 32 base64 bytes")
    end
  end

  defp destroy(pid, k, n) do
    Agent.get_and_update(pid, fn st ->
      with rec when not is_nil(rec) <- Map.get(st.keys, k),
           {i, ""} <- Integer.parse(n),
           v when not is_nil(v) <- Enum.at(rec.versions, i - 1) do
        nv = v |> Map.drop([:key, :priv]) |> Map.put(:state, "DESTROYED")
        rec = %{rec | versions: List.replace_at(rec.versions, i - 1, nv)}
        {{200, ver_json(k, nv)}, put_in(st.keys[k], rec)}
      else
        _ -> {err(404, "NOT_FOUND", "key version not found"), st}
      end
    end)
  end

  defp update_primary(pid, k, n) do
    Agent.get_and_update(pid, fn st ->
      with rec when not is_nil(rec) <- Map.get(st.keys, k),
           {i, ""} <- Integer.parse(n || ""),
           %{state: "ENABLED"} <- Enum.at(rec.versions, i - 1) do
        rec = %{rec | primary: i}
        {{200, key_json(k, rec)}, put_in(st.keys[k], rec)}
      else
        _ -> {err(400, "FAILED_PRECONDITION", "version not enabled or not found"), st}
      end
    end)
  end

  # -- helpers --------------------------------------------------------------

  defp with_key(pid, k, fun) do
    case Agent.get(pid, &Map.get(&1.keys, k)) do
      nil -> err(404, "NOT_FOUND", "CryptoKey not found")
      rec -> fun.(k, rec)
    end
  end

  defp with_version(pid, k, n, fun) do
    with_key(pid, k, fn _k, rec ->
      case Integer.parse(n) do
        {i, ""} when i >= 1 ->
          case Enum.at(rec.versions, i - 1) do
            nil -> err(404, "NOT_FOUND", "key version not found")
            v -> fun.(rec, v)
          end

        _ ->
          err(404, "NOT_FOUND", "key version not found")
      end
    end)
  end

  defp pem(pub), do: :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, pub}, {:namedCurve, @oid}})])

  defp b64(nil), do: :error
  defp b64(s), do: Base.decode64(s)
  defp aad(body), do: (case b64(body["additionalAuthenticatedData"]) do {:ok, a} -> a; _ -> "" end)

  defp rname({p, l, r}), do: "projects/#{p}/locations/#{l}/keyRings/#{r}"
  defp kname({p, l, r, id}), do: rname({p, l, r}) <> "/cryptoKeys/#{id}"
  defp vname(k, n), do: kname(k) <> "/cryptoKeyVersions/#{n}"
  defp ver_json(k, v), do: %{"name" => vname(k, v.n), "state" => v.state}

  defp key_json(k, rec) do
    base = %{"name" => kname(k), "purpose" => rec.purpose, "primary" => ver_json(k, Enum.at(rec.versions, rec.primary - 1))}
    base = if rec.rotation_period, do: Map.put(base, "rotationPeriod", rec.rotation_period), else: base
    if rec.next_rotation, do: Map.put(base, "nextRotationTime", rec.next_rotation), else: base
  end

  defp err(code, status, msg), do: {code, %{"error" => %{"code" => code, "status" => status, "message" => msg}}}
end
