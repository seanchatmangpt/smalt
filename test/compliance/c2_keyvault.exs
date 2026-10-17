defmodule Compliance.C2KeyvaultTest do
  @moduledoc """
  C2 compliance fences: smalt's Key Vault / Managed HSM data-plane surface vs
  the real Key Vault REST 7.x contract + Secure Key Release spec.

  Companion doc: `docs/compliance/C2_KEYVAULT.md` (per-row verdicts with code
  citations and live-probe evidence). This suite fences the CONFORMANT rows:
  every assertion here passed against a real TLS round trip on the day the
  doc was written; if the wire shape regresses, the corresponding row in the
  doc must be re-graded.

  Known deviations (documented, not fenced as conformant):
  - release request contract ignores the real `target`/`enc`/`nonce` body
    (MAA token read from the Authorization header; smalt release errors
    UnauthorizedAttestation/TokenReplay are smalt spellings);
  - release response value is derived material, not the real signed object
    containing the KeyBundle;
  - smalt's own MAA token still emits the flat claim form (x-ms-compliance-
    status top-level; Security.Attestation is outside this surface); SKR
    admission accepts BOTH flat and the real nested x-ms-isolation-tee form
    (fenced C2.9b).
  """

  use ExUnit.Case, async: false

  @cert "tmp/dev-cert.pem"
  @key "tmp/dev-key.pem"

  # Wire encoding: base64url without padding, per the real KV contract.
  defp b64u(bin), do: Base.url_encode64(bin, padding: false)
  defp b64u_decode!(s), do: Base.url_decode64!(s, padding: false)

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(l)
    :gen_tcp.close(l)
    port
  end

  setup_all do
    {:ok, cert, _key} =
      case Smalt.TLS.ensure_dev_cert() do
        {:ok, c, k} -> {:ok, c, k}
        {:error, _} -> Smalt.TLS.write_dev_cert(@cert, @key)
      end

    [cert: Path.expand(cert)]
  end

  setup do
    {:ok, cert, _key} =
      case Smalt.TLS.ensure_dev_cert() do
        {:ok, c, k} -> {:ok, c, k}
        {:error, _} -> Smalt.TLS.write_dev_cert(@cert, @key)
      end

    {port, opts} = boot_twin(10)
    {:ok, sup} = Supervisor.start_link([{Bandit, opts}], strategy: :one_for_one)
    wait_twin(port, 50)

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 1000)
      catch
        _, _ -> Process.exit(sup, :kill)
      end
    end)

    [port: port, cert: Path.expand(cert)]
  end

  defp boot_twin(0), do: raise("could not bind a free TLS twin port after 10 attempts")

  defp boot_twin(tries) do
    port = free_port()
    opts = Smalt.TLS.bandit_opts(Smalt.Application.TlsTwinDispatch, port)

    if opts[:scheme] != :https, do: raise("dev TLS cert unavailable: #{inspect(opts)}")

    if port_free?(port), do: {port, opts}, else: boot_twin(tries - 1)
  end

  defp port_free?(port) do
    case :gen_tcp.listen(port, []) do
      {:ok, l} ->
        :gen_tcp.close(l)
        true

      {:error, _} ->
        false
    end
  end

  defp wait_twin(_port, 0), do: :ok

  defp wait_twin(port, n) do
    alive? =
      case :ssl.connect(~c"localhost", port, [verify: :verify_none, active: false], 1000) do
        {:ok, s} ->
          :ssl.close(s)
          true

        _ ->
          false
      end

    if alive?, do: :ok, else: (Process.sleep(100) && wait_twin(port, n - 1))
  end

  # -- real-TLS HTTP client (verify_none is fine here: the pin/hostname
  # verification itself is fenced by test/kv_tls_test.exs) --------------

  defp https(ctx, method, path, body \\ nil, headers \\ []) do
    {s, _h, b} = https_full(ctx, method, path, body, headers)
    {s, b}
  end

  # Lens-3 cross-court round 2: header-exposing variant — the response
  # content-type fact is pinned byte-identical on ARM (c1) and Cosmos (c3);
  # the Key Vault plane shares the same send_json seam and gets the same pin.
  defp https_full(ctx, method, path, body \\ nil, headers \\ []) do
    req =
      [
        "#{method} #{path} HTTP/1.1",
        "Host: localhost",
        "Connection: close",
        "Content-Type: application/json"
      ] ++
        Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end) ++
        case body do
          nil -> ["Content-Length: 0"]
          b -> ["Content-Length: #{byte_size(b)}"]
        end ++
        ["", body || ""]

    {:ok, sock} = :ssl.connect(~c"localhost", ctx.port, [verify: :verify_none, active: false], 5000)
    :ok = :ssl.send(sock, IO.iodata_to_binary(Enum.join(req, "\r\n")))
    data = recv_all(sock, [])
    :ssl.close(sock)

    [header_block | rest] = String.split(data, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(header_block, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ", parts: 3)

    body_out =
      case rest do
        [raw] ->
          if Regex.match?(~r/^[0-9a-fA-F]+\r\n/, raw), do: dechunk(raw), else: raw

        [] ->
          ""
      end

    headers =
      header_lines
      |> Enum.map(fn line ->
        case String.split(line, ": ", parts: 2) do
          [k, v] -> {String.downcase(k), v}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {String.to_integer(status), headers, body_out}
  end

  defp recv_all(sock, acc) do
    case :ssl.recv(sock, 0, 5000) do
      {:ok, d} -> recv_all(sock, [acc | d])
      {:error, _} -> IO.iodata_to_binary(acc)
    end
  end

  defp dechunk(raw, acc \\ []) do
    case String.split(raw, "\r\n", parts: 2) do
      [size_line, rest] ->
        case Integer.parse(size_line, 16) do
          {0, _} -> IO.iodata_to_binary(Enum.reverse(acc))
          {n, _} ->
            <<chunk::binary-size(n), "\r\n", rem::binary>> = rest
            dechunk(rem, [chunk | acc])
        end

      _ -> IO.iodata_to_binary(Enum.reverse(acc))
    end
  end

  defp json(""), do: %{"_empty" => true}
  defp json(body), do: Jason.decode!(body)

  # -- helpers -----------------------------------------------------------

  defp create_key(ctx, name, params) do
    {status, body} = https(ctx, "POST", "/keys/#{name}/create", Jason.encode!(params))
    assert status == 200, "create #{name} returned #{status}: #{inspect(body)}"
    json(body)
  end

  defp attest do
    measurement = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    Smalt.Store.put(:smalt_attestation_baseline, measurement, measurement)
    {:ok, token, claims} = Smalt.Security.Attestation.attest_enclave(%{"measurement" => measurement})
    {token, claims}
  end

  # -- C2.1 key create envelope -------------------------------------------

  test "C2.1 create returns KeyBundle envelope with kid/kty/attributes", ctx do
    name = "c2-create-#{System.unique_integer([:positive])}"
    created = create_key(ctx, name, %{"kty" => "RSA-HSM"})

    assert created["key"]["kty"] == "RSA-HSM"
    assert created["kid"] =~ "https://" and created["kid"] =~ "/keys/#{name}/"
    assert created["key"]["kid"] =~ "https://" and created["key"]["kid"] =~ "/keys/#{name}"
    assert created["attributes"]["enabled"] == true
    assert is_integer(created["attributes"]["created"])
    # release-policy absence marks the key non-exportable, matching the
    # exportable flag semantics
    assert created["attributes"]["exportable"] == false
    refute Map.has_key?(created, "key_material")
  end

  # C2.1 pin: kty default. Real Key Vault defaults to RSA-HSM (HSM-protected)
  # when kty is omitted; the wire must not silently fall back to software RSA.
  test "C2.1-pin create with no kty defaults to RSA-HSM", ctx do
    name = "c2-kty-default-#{System.unique_integer([:positive])}"
    created = create_key(ctx, name, %{"attributes" => %{"enabled" => true}})

    assert created["key"]["kty"] == "RSA-HSM"
  end

  test "C2.1b exportable flag follows the release policy", ctx do
    name = "c2-create-pol-#{System.unique_integer([:positive])}"

    created =
      create_key(ctx, name, %{
        "kty" => "RSA-HSM",
        "release_policy" => %{"allowed_operations" => ["encrypt"]}
      })

    assert created["attributes"]["exportable"] == true
    assert created["release_policy"]["allowed_operations"] == ["encrypt"]
  end

  # -- C2.2 RSA-OAEP-256 encrypt/decrypt -----------------------------------

  test "C2.2 RSA-OAEP-256 encrypt/decrypt round trip, response {value, kid}", ctx do
    name = "c2-rsa-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "RSA-HSM"})
    plain = :crypto.strong_rand_bytes(32)

    {s, b} =
      https(ctx, "POST", "/keys/#{name}/encrypt", Jason.encode!(%{"alg" => "RSA-OAEP-256", "value" => b64u(plain)}))

    assert s == 200, "encrypt returned #{s}: #{inspect(b)}"
    enc = json(b)
    assert %{"value" => ct, "kid" => kid} = enc
    assert kid =~ "/keys/#{name}"
    # base64url wire form: no padding, no +/ alphabet
    refute ct =~ "=" and ct =~ "+" and ct =~ "/"

    {s, b} =
      https(ctx, "POST", "/keys/#{name}/decrypt", Jason.encode!(%{"alg" => "RSA-OAEP-256", "value" => ct}))

    assert s == 200, "decrypt round trip returned #{s}: #{inspect(b)}"
    assert json(b)["value"] |> b64u_decode!() == plain

    # compat: a standard-base64 input is also accepted on the wire
    {s, _} =
      https(ctx, "POST", "/keys/#{name}/encrypt", Jason.encode!(%{"alg" => "RSA-OAEP-256", "value" => Base.encode64(plain)}))

    assert s == 200
  end

  # -- C2.3 oct/A256GCM ------------------------------------------------------

  test "C2.3 oct key A256GCM round trip with iv/tag echo", ctx do
    name = "c2-oct-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "oct"})
    plain = :crypto.strong_rand_bytes(24)
    iv = :crypto.strong_rand_bytes(12)

    {s, b} =
      https(ctx, "POST", "/keys/#{name}/encrypt",
        Jason.encode!(%{"alg" => "A256GCM", "value" => b64u(plain), "iv" => b64u(iv)}))

    assert s == 200, "encrypt returned #{s}: #{inspect(b)}"
    enc = json(b)
    assert %{"value" => ct, "tag" => tag, "iv" => iv_out} = enc

    {s, b} =
      https(ctx, "POST", "/keys/#{name}/decrypt",
        Jason.encode!(%{"alg" => "A256GCM", "value" => ct, "iv" => iv_out, "tag" => tag}))

    assert s == 200, "decrypt returned #{s}: #{inspect(b)}"
    assert json(b)["value"] |> b64u_decode!() == plain
  end

  # -- C2.4 algorithm gating + error codes ------------------------------------

  test "C2.4 alg/key-type mismatches and unknown algs refuse with exact codes", ctx do
    name = "c2-alg-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "RSA-HSM"})

    {s, b} =
      https(ctx, "POST", "/keys/#{name}/encrypt", Jason.encode!(%{"alg" => "A256GCM", "value" => Base.encode64("x")}))

    assert s == 400 and json(b)["error"]["code"] == "InvalidAlgorithm"

    {s, b} = https(ctx, "POST", "/keys/#{name}/sign", Jason.encode!(%{"alg" => "RS512", "value" => Base.encode64("x")}))
    assert s == 400 and json(b)["error"]["code"] == "InvalidAlgorithm"

    {s, b} = https(ctx, "POST", "/keys/#{name}/sign", Jason.encode!(%{"value" => Base.encode64("x")}))
    assert s == 400 and json(b)["error"]["code"] == "InvalidAlgorithm"

    {s, b} = https(ctx, "POST", "/keys/#{name}/decrypt", Jason.encode!(%{"alg" => "RSA-OAEP-256", "value" => "not-base64!!"}))
    assert s == 400 and json(b)["error"]["code"] == "InvalidValue"

    {s, b} = https(ctx, "GET", "/keys/no-such-c2-#{System.unique_integer()}")
    assert s == 404 and json(b)["error"]["code"] == "KeyNotFound"

    {s, b} = https(ctx, "GET", "/keys/no-such-c2-#{System.unique_integer()}/versions")
    assert s == 404 and json(b)["error"]["code"] == "KeyNotFound"
  end

  test "C2.4b response content-type is the same JSON bytes the ARM and Cosmos planes emit (lens-3 cross-court round 2)",
       ctx do
    name = "c2-ct-#{System.unique_integer([:positive])}"

    {200, headers, _body} = https_full(ctx, "POST", "/keys/#{name}/create", Jason.encode!(%{"kty" => "RSA-HSM"}))
    hm = Map.new(headers)
    assert hm["content-type"] == "application/json; charset=utf-8"

    {404, err_headers, _body} = https_full(ctx, "GET", "/keys/no-such-c2-ct-#{System.unique_integer([:positive])}")
    assert Map.new(err_headers)["content-type"] == "application/json; charset=utf-8"
  end

  # -- C2.5 sign / verify -------------------------------------------------------

  test "C2.5 sign RS256/PS256 over digest, verify {value: bool}", ctx do
    name = "c2-sign-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "RSA-HSM"})

    for alg <- ["RS256", "PS256"] do
      digest = :crypto.hash(:sha256, "payload")

      {s, b} = https(ctx, "POST", "/keys/#{name}/sign", Jason.encode!(%{"alg" => alg, "digest" => b64u(digest)}))
      assert s == 200, "sign #{alg} returned #{s}: #{inspect(b)}"
      assert %{"value" => sig, "kid" => kid} = json(b)
      assert is_binary(sig) and kid =~ "/keys/#{name}"

      # real contract: digest + signature-in-value, response {"value": bool}
      {s, b} = https(ctx, "POST", "/keys/#{name}/verify", Jason.encode!(%{"alg" => alg, "digest" => b64u(digest), "value" => sig}))
      assert s == 200, "verify #{alg} returned #{s}: #{inspect(b)}"
      assert json(b)["value"] == true
      assert json(b)["valid"] == true, "compat alias 'valid' must mirror 'value'"

      {s, b} = https(ctx, "POST", "/keys/#{name}/verify", Jason.encode!(%{"alg" => alg, "digest" => b64u(digest), "value" => b64u(:crypto.strong_rand_bytes(32))}))
      assert s == 200 and json(b)["value"] == false

      # compat path: pre-image in value, signature in signature
      {s, b} = https(ctx, "POST", "/keys/#{name}/verify", Jason.encode!(%{"alg" => alg, "value" => b64u("payload"), "signature" => sig}))
      assert s == 200 and json(b)["value"] == true
    end
  end

  # -- C2.6 release-policy operation gate -----------------------------------------

  test "C2.6 operations outside allowed_operations refuse OperationNotAllowed", ctx do
    name = "c2-policy-#{System.unique_integer([:positive])}"

    create_key(ctx, name, %{
      "kty" => "RSA-HSM",
      "release_policy" => %{"allowed_operations" => ["encrypt"]}
    })

    {s, b} = https(ctx, "POST", "/keys/#{name}/encrypt", Jason.encode!(%{"alg" => "RSA-OAEP-256", "value" => Base.encode64("x")}))
    assert s == 200

    {s, b} = https(ctx, "POST", "/keys/#{name}/sign", Jason.encode!(%{"alg" => "RS256", "value" => Base.encode64("x")}))
    assert s == 403
    assert json(b)["error"]["code"] == "OperationNotAllowed"

    {s, b} = https(ctx, "POST", "/keys/#{name}/decrypt", Jason.encode!(%{"alg" => "RSA-OAEP-256", "value" => Base.encode64("x")}))
    assert s == 403
    assert json(b)["error"]["code"] == "OperationNotAllowed"
  end

  # -- C2.7 list / versions --------------------------------------------------------

  test "C2.7 GET /keys and /versions return {value: [...]} with kid+attributes, no private material", ctx do
    name = "c2-list-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "RSA-HSM", "tags" => %{"env" => "c2"}})

    {s, b} = https(ctx, "GET", "/keys")
    assert s == 200
    %{"value" => keys} = json(b)
    assert is_list(keys)
    entry = Enum.find(keys, fn rec -> is_map(rec) and rec["kid"] =~ name end)
    assert entry, "created key missing from listing"
    assert entry["attributes"]["enabled"] == true

    {s, b} = https(ctx, "GET", "/keys/#{name}/versions")
    assert s == 200
    %{"value" => [version]} = json(b)
    assert version["kid"] =~ "/keys/#{name}"
    assert version["attributes"]
  end

  # -- C2.8 Secure Key Release --------------------------------------------------------

  test "C2.8 release: KeyNotExportable / UnauthorizedAttestation / success / jti replay", ctx do
    name = "c2-skr-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "RSA-HSM"})

    {s, b} = https(ctx, "POST", "/keys/#{name}/release", "{}")
    assert s == 400 and json(b)["error"]["code"] == "KeyNotExportable"

    pol_name = name <> "-pol"
    create_key(ctx, pol_name, %{"kty" => "RSA-HSM", "release_policy" => %{"allowed_operations" => ["encrypt"]}})

    {s, b} = https(ctx, "POST", "/keys/#{pol_name}/release", "{}")
    assert s == 403 and json(b)["error"]["code"] == "UnauthorizedAttestation"

    {token, claims} = attest()
    assert claims["x-ms-compliance-status"] == "azure-compliant-cvm"

    {s, b} = https(ctx, "POST", "/keys/#{pol_name}/release", "{}", [{"authorization", "Bearer " <> token}])
    assert s == 200, "release returned #{s}: #{inspect(b)}"
    released = json(b)
    assert %{"value" => material, "kid" => kid, "keyMaterialVersion" => 1, "policyHash" => hash, "status" => "Released"} = released
    assert is_binary(material) and byte_size(material) > 0
    assert kid =~ "/keys/#{pol_name}"
    assert b64u_decode!(hash) |> byte_size() == 32

    {s, b} = https(ctx, "POST", "/keys/#{pol_name}/release", "{}", [{"authorization", "Bearer " <> token}])
    assert s == 403
    assert json(b)["error"]["code"] == "TokenReplay"
  end

  test "C2.8b policy hash separates keys and policies; version increments", ctx do
    n1 = "c2-skr-a-#{System.unique_integer([:positive])}"
    n2 = "c2-skr-b-#{System.unique_integer([:positive])}"
    create_key(ctx, n1, %{"kty" => "oct", "release_policy" => %{"allowed_operations" => ["release"]}})

    create_key(ctx, n2, %{"kty" => "oct", "release_policy" => %{"allowed_operations" => ["release"]}})

    {t1, _} = attest()
    {t2, _} = attest()

    {s1, b1} = https(ctx, "POST", "/keys/#{n1}/release", "{}", [{"authorization", "Bearer " <> t1}])
    {s2, b2} = https(ctx, "POST", "/keys/#{n2}/release", "{}", [{"authorization", "Bearer " <> t2}])
    assert s1 == 200 and s2 == 200
    r1 = json(b1)
    r2 = json(b2)
    assert r1["value"] != r2["value"], "different keys must release different material"
    assert r1["policyHash"] == r2["policyHash"], "same policy content must hash equal"
    assert r1["keyMaterialVersion"] == 1 and r2["keyMaterialVersion"] == 1
  end

  test "C2.1c create returns a real JsonWebKey (n = modulus b64url, e = AQAB; oct k)", ctx do
    name = "c2-jwk-#{System.unique_integer([:positive])}"
    created = create_key(ctx, name, %{"kty" => "RSA-HSM"})

    n = created["key"]["n"]
    e = created["key"]["e"]
    assert is_binary(n) and byte_size(b64u_decode!(n)) == 256
    assert e == "AQAB"
    refute n == "AQAB"

    oct_name = "c2-jwk-oct-#{System.unique_integer([:positive])}"
    oct_created = create_key(ctx, oct_name, %{"kty" => "oct"})
    assert is_binary(oct_created["key"]["k"]) and byte_size(b64u_decode!(oct_created["key"]["k"])) == 32
  end

  test "C2.6b Azure anyOf/allOf/claim/equals policy accepted verbatim; bogus policy refused", ctx do
    name = "c2-azure-pol-#{System.unique_integer([:positive])}"

    azure_policy = %{
      "anyOf" => [
        %{"allOf" => [%{"claim" => "c1", "equals" => "v1"}, %{"claim" => "c2", "equals" => "v2"}]}
      ],
      "version" => "1.0.0",
      "contentType" => "application/json"
    }

    created = create_key(ctx, name, %{"kty" => "RSA-HSM", "release_policy" => azure_policy})
    assert created["release_policy"] == azure_policy, "policy must be stored verbatim"
    assert created["attributes"]["exportable"] == true

    # SKR release works against an Azure-grammar policy
    {token, _claims} = attest()

    {s, b} = https(ctx, "POST", "/keys/#{name}/release", "{}", [{"authorization", "Bearer " <> token}])
    assert s == 200, "release with Azure policy returned #{s}: #{inspect(b)}"
    assert json(b)["policyHash"]

    bad_name = name <> "-bad"

    {s, b} =
      https(ctx, "POST", "/keys/#{bad_name}/create",
        Jason.encode!(%{"kty" => "RSA-HSM", "release_policy" => %{"nonsense" => true}}))

    assert s == 400 and json(b)["error"]["code"] == "InvalidParameter"
  end

  # -- C2.9 attestation claim surface (documented deviation, fence the smalt form)

  test "C2.9 MAA token carries smalt's flat claim form with sevsnpvm + isolation TEE", ctx do
    {_token, claims} = attest()
    assert claims["x-ms-attestation-type"] == "sevsnpvm"
    assert claims["x-ms-isolation-tee"] == "AMD-SEV-SNP"
    assert get_in(claims, ["x-ms-runtime", "jti"])
  end

  test "C2.9b SKR admission accepts the real nested x-ms-isolation-tee MAA form", ctx do
    name = "c2-nested-#{System.unique_integer([:positive])}"
    create_key(ctx, name, %{"kty" => "RSA-HSM", "release_policy" => %{"allowed_operations" => ["release"]}})

    now = System.system_time(:second)

    nested_claims = %{
      "iss" => "https://real-maa.example/",
      "iat" => now,
      "exp" => now + 600,
      "x-ms-isolation-tee" => %{
        "x-ms-attestation-type" => "sevsnpvm",
        "x-ms-compliance-status" => "azure-compliant-cvm",
        "x-ms-runtime" => %{"jti" => Integer.to_string(System.unique_integer([:positive]))}
      }
    }

    token = Smalt.Security.ReceiptSigner.sign(nested_claims)

    {s, b} = https(ctx, "POST", "/keys/#{name}/release", "{}", [{"authorization", "Bearer " <> token}])
    assert s == 200, "release with nested MAA claims returned #{s}: #{inspect(b)}"
    assert json(b)["status"] == "Released"
  end

  defp ctx_key_host, do: "localhost:8443"
end
