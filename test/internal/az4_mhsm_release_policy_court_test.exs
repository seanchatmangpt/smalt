defmodule Internal.AZ4MhsmReleasePolicyCourtTest do
  # AZ-4 (v26.10.22): MHSM key release-policy face court over the real TLS
  # twin wire, KD-166. Restrictive-policy key: in-policy release succeeds with
  # a receipt (keyMaterialVersion/released receipt), assertion-violating
  # release is the typed 403 KeyReleasePolicyViolation and leaves the key row
  # unchanged (no version burn), policy-less key release is the typed
  # 400 KeyNotExportable policy-required refusal, GET echoes the stored
  # policy verbatim, and the evaluator itself is negative-fixture fenced
  # (empty anyOf refuses; unknown condition refuses; nested
  # x-ms-isolation-tee claim resolves). No mocks — real signer, real wire.
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.MHSM
  alias Smalt.Security.ReceiptSigner

  @api_version "7.4"
  @token_key :az4_mhsm_sts_token

  @policy %{
    "dataExecution" => "never",
    "exportable" => "never",
    "anyOf" => [
      %{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "sevsnpvm"}
    ]
  }

  @tag :az4
  test "leg 1: create with restrictive policy, GET echoes policy verbatim" do
    {base, cert} = twin()
    name = unique("az4-policy")

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", %{
        "kty" => "RSA-HSM",
        "release_policy" => @policy
      })

    assert status == 200, "create: #{inspect(body)}"
    assert body["key"]["kty"] == "RSA-HSM"
    assert body["release_policy"] == @policy
    assert body["attributes"]["exportable"] == true

    {get_status, get_body} = authed(:get, base, cert, "/keys/#{name}?api-version=#{@api_version}", %{})
    assert get_status == 200
    assert get_body["release_policy"] == @policy
  end

  @tag :az4
  test "leg 2: release within policy succeeds with receipt; violating release is typed 403 and leaves key unchanged" do
    {base, cert} = twin()
    name = unique("az4-release")

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", %{
        "kty" => "RSA-HSM",
        "release_policy" => @policy
      })

    assert status == 200, "create: #{inspect(body)}"

    # In-policy release: attestation type matches the anyOf assertion.
    {rel_status, rel_body} = release(base, cert, name, %{"x-ms-attestation-type" => "sevsnpvm"})

    assert rel_status == 200, "release: #{inspect(rel_body)}"
    assert rel_body["status"] == "Released"
    assert rel_body["release_policy_applied"] == true
    assert rel_body["keyMaterialVersion"] == 1
    assert rel_body["kid"] == body["kid"]
    assert is_binary(rel_body["value"]) and rel_body["value"] != ""

    # Violating release: wrong assertion value -> typed MHSM refusal.
    {bad_status, bad_body} =
      release(base, cert, name, %{"x-ms-attestation-type" => "fake-tee"})

    assert bad_status == 403, "expected 403, got #{bad_status}: #{inspect(bad_body)}"
    assert bad_body["error"]["code"] == "KeyReleasePolicyViolation"

    # Key unchanged: the violating attempt burned no version and altered no
    # row — a subsequent compliant release is still keyMaterialVersion 2
    # (one successful release so far), and the stored policy is intact.
    {ok_status, ok_body} = release(base, cert, name, %{"x-ms-attestation-type" => "sevsnpvm"})
    assert ok_status == 200
    assert ok_body["keyMaterialVersion"] == 2

    {get_status, get_body} = authed(:get, base, cert, "/keys/#{name}?api-version=#{@api_version}", %{})
    assert get_status == 200
    assert get_body["release_policy"] == @policy
  end

  @tag :az4
  test "leg 3: policy-less key release is the typed policy-required refusal" do
    {base, cert} = twin()
    name = unique("az4-nopolicy")

    {status, body} =
      authed(:post, base, cert, "/keys/#{name}/create?api-version=#{@api_version}", %{
        "kty" => "oct-HSM"
      })

    assert status == 200, "create: #{inspect(body)}"

    {rel_status, rel_body} = release(base, cert, name, %{"x-ms-attestation-type" => "sevsnpvm"})

    assert rel_status == 400, "expected 400, got #{rel_status}: #{inspect(rel_body)}"
    assert rel_body["error"]["code"] == "KeyNotExportable"
  end

  @tag :az4
  test "leg 4 (negative fixtures): evaluator fails closed on empty anyOf, unknown condition, nested tee claim resolves" do
    # Empty anyOf = allow-nothing: must refuse, never vacuously allow.
    assert {:error, 403, %{}} =
             MHSM.evaluate_policy(%{"anyOf" => []}, %{"x-ms-attestation-type" => "sevsnpvm"})

    # Unknown condition verb refuses (fail-closed), even with equal values.
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation"}}} =
             MHSM.evaluate_policy(
               %{"anyOf" => [%{"claim" => "c", "condition" => "matches", "value" => "x"}]},
               %{"c" => "x"}
             )

    # contains matches a substring; nil actual under contains refuses.
    assert :ok =
             MHSM.evaluate_policy(
               %{"anyOf" => [%{"claim" => "x-ms-compliance-status", "condition" => "contains", "value" => "cvm"}]},
               %{"x-ms-compliance-status" => "azure-compliant-cvm"}
             )

    assert {:error, 403, _} =
             MHSM.evaluate_policy(
               %{"anyOf" => [%{"claim" => "x-ms-compliance-status", "condition" => "contains", "value" => "cvm"}]},
               %{"x-ms-isolation-tee" => %{"x-ms-compliance-status" => nil}}
             )

    # Nested MAA form: claim inside x-ms-isolation-tee resolves.
    assert :ok =
             MHSM.evaluate_policy(
               %{
                 "assertions" => [
                   %{"claim" => "x-ms-attestation-type", "condition" => "equals", "value" => "sevsnpvm"}
                 ]
               },
               %{"x-ms-isolation-tee" => %{"x-ms-attestation-type" => "sevsnpvm"}}
             )

    # ops-only policy (allowed_operations, no claim assertions): no claim
    # constraint -> :ok.
    assert :ok = MHSM.evaluate_policy(%{"allowed_operations" => ["sign"]}, %{})

    # nil policy through the evaluator is a refusal (policy-required face).
    assert {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation"}}} =
             MHSM.evaluate_policy(nil, %{})
  end

  # ---------------------------------------------------------------------------

  defp unique(prefix), do: "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

  defp release(base, cert, name, extra_claims) do
    now = System.system_time(:second)

    # Real RS256 signer; verification happens server-side in SKR.authorized?.
    claims =
      Map.merge(
        %{
          "iss" => "https://smalt-attestation.local/",
          "iat" => now,
          "exp" => now + 600,
          "x-ms-attestation-type" => "sevsnpvm",
          "x-ms-compliance-status" => "azure-compliant-cvm",
          "x-ms-isolation-tee" => "AMD-SEV-SNP"
        },
        extra_claims
      )

    authed(
      :post,
      base,
      cert,
      "/keys/#{name}/release?api-version=#{@api_version}",
      %{},
      ReceiptSigner.sign(claims)
    )
  end

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  defp authed(method, base, cert, path, params, token \\ nil) when is_map(params) do
    authed_req(method, base, cert, path, Jason.encode!(params), token)
  end

  defp authed_req(method, base, cert, path, body, token) do
    case request(method, base, cert, path, body, token) do
      {401, _} ->
        :persistent_term.put(@token_key, fetch_sts_token(base, cert))
        request(method, base, cert, path, body, token)

      other ->
        other
    end
  end

  defp request(method, base, cert, path, body, token) do
    auth =
      case token || :persistent_term.get(@token_key, nil) do
        nil -> "Bearer anonymous-probe"
        tok -> "Bearer #{tok}"
      end

    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      String.upcase(Atom.to_string(method)),
      "-H",
      "Authorization: #{auth}",
      "-H",
      "Content-Type: application/json",
      "-d",
      body,
      "-w",
      "\n%{http_code}",
      "#{base}#{path}"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)
    parts = String.split(String.trim_trailing(out), "\n")
    code = List.last(parts) |> String.to_integer()
    raw = parts |> Enum.drop(-1) |> Enum.join("\n")
    decoded = if raw == "", do: %{}, else: Jason.decode!(raw)
    {code, decoded}
  end

  defp fetch_sts_token(base, cert) do
    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=az4-lane&client_secret=az4-lane&scope=https://vault.azure.net/.default",
      "#{base}/organizations/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

    case Jason.decode(out) do
      {:ok, %{"access_token" => tok}} when is_binary(tok) -> tok
      other -> flunk("STS token fetch failed: #{inspect(other)}")
    end
  end
end
