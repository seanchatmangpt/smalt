# AZ-2 MAA attestation court (v26.10.22, lane az2).
#
# Contract: Azure Managed Attestation PROTOCOL face over the landed
# attestation surface (docs/jira/v26.10.22/receipts/az2-maa-attestation.md).
#
# Court legs (Chicago: real signer, real policy grammar, real CTRT seal via
# the real wasm engine, real VC via VcExport, real SKR release face):
#   1. valid measurement structure -> {:ok, token, claims}; the JWS payload
#      binds measurement_digest + ctrt_sha256; verified via
#      ReceiptSigner.verify / Maa.verify_attestation.
#   2. tampered measurement byte -> typed 400 invalidmeasurement with a
#      chain-complete andon refusal leaf (BK-111 PROV-O chain).
#   3. replayed nonce -> typed nonceReplay refusal + andon leaf.
#   4. MAA policy grammar: authorizationrules gate, issuancerules derive
#      claims (type=sevsnpvm, x-ms-isolation-tee).
#   5. VC 2.0 binding: verified VC binds proof sha; tampered VC refuses.
#   6. SKR witness: valid measurement JWT -> key release admitted;
#      tampered measurement -> typed 403 refusal.
#   7. TEE honesty: the only supported :type is SevSnpVM; unsupported TEE
#      families refuse typed (hardware quote production = UNSUPPORTED).
#
# Bounded polls only, zero sleeps.

Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.Az2MaaAttestationCourtTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 1]

  alias Smalt.Attestation.Maa
  alias Smalt.Receipt.VcExport
  alias Smalt.Security.ReceiptSigner
  alias Smalt.Store

  @measurement :crypto.strong_rand_bytes(32)
  @measurement_hex Base.encode16(@measurement, case: :lower)

  setup do
    Maa.reset_nonces!()

    # Real CTRT from the real wasm engine (BK-85 seal path).
    assert eventually(fn ->
             case Code.ensure_loaded(Smalt.Affidavit.WasmEngine) do
               {:module, _} -> {:ok, true}
               _ -> {:engine_module, false}
             end
           end)

    :ok
  end

  defp quote_bytes(measurement, runtime_json) do
    <<"SMQ1", measurement::binary-size(32), byte_size(runtime_json)::unsigned-integer-size(32),
      runtime_json::binary>>
  end

  defp runtime_data(claims), do: runtime_data_for(@measurement, claims)

  defp runtime_data_for(measurement, claims) do
    json = Jason.encode!(claims)

    %{
      "report" => Base.url_encode64(quote_bytes(measurement, json), padding: false),
      "runtimeData" => %{"data" => Base.encode64(json), "dataType" => "JSON"}
    }
  end

  defp real_ctrt do
    delta = Jason.encode!(%{probe: "az2-court", n: System.unique_integer([:positive])})

    assert {:ok, %{ctrt_bytes: ctrt}} =
             Smalt.Affidavit.WasmEngine.call_admit_and_seal(delta, 1, 1, %{})

    assert byte_size(ctrt) == 352
    ctrt
  end

  defp vc_for_term do
    term =
      <<0x534D_4C54::32, 1::32, 3::64, :crypto.strong_rand_bytes(32)::binary, 0::(272 * 8)>>

    VcExport.to_vc(term, issuer: "did:web:substrate.loopback", seq_horizon: {1, 3})
  end

  @tag :smalt_internal
  test "api-version pin: the face serves 2022-08-01 (real MAA REST doc)" do
    assert Maa.api_version() == "2022-08-01"
    assert Maa.default_policy() =~ "authorizationrules"
    assert Maa.default_policy() =~ "issuancerules"
  end

  @tag :smalt_internal
  test "valid measurement -> JWS binding measurement_digest + ctrt_sha256 (verified via ReceiptSigner)" do
    ctrt = real_ctrt()

    assert {:ok, token, claims} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex}),
               bind_ctrt: ctrt
             )

    assert is_binary(token)
    assert claims["measurement_digest"] == @measurement_hex
    assert claims["ctrt_sha256"] == Base.encode16(:crypto.hash(:sha256, ctrt), case: :lower)
    assert claims["ctrt_probe_region_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, binary_part(ctrt, 70, 32)), case: :lower)
    assert claims["x-ms-compliance-status"] == "azure-compliant-cvm"

    # Signature verification through the REAL signer, twice:
    assert {:ok, payload} = ReceiptSigner.verify(token)
    assert payload["measurement_digest"] == @measurement_hex
    assert {:ok, _} = Maa.verify_attestation(token)
  end

  @tag :smalt_internal
  test "VC 2.0 binding: verified VC binds proof sha; tampered VC refuses typed" do
    vc = vc_for_term()

    assert {:ok, token, claims} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex}),
               bind_vc: vc
             )

    assert claims["vc_proof_sha256"] == vc["proof"]["proofPayloadSha256"]
    assert {:ok, payload} = Maa.verify_attestation(token)
    assert payload["vc_receipt_digest"] == vc["credentialSubject"]["receiptDigest"]

    tampered = put_in(vc, ["credentialSubject", "frameCount"], 999)

    assert {:error, 400, %{"error" => %{"code" => code}}, andon} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex}),
               bind_vc: tampered
             )

    assert code =~ "invalidparameter"
    assert :ok = Smalt.Powl2.Andon.verify_ntriples(Smalt.Powl2.Andon.ntriples(andon))
  end

  @tag :smalt_internal
  test "tampered measurement byte -> typed 400 invalidmeasurement + chain-complete andon leaf" do
    <<a, b, rest::binary>> = @measurement
    tampered_hex = Base.encode16(<<a, b + 1, rest::binary>>, case: :lower)

    assert {:error, 400, body, andon} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => tampered_hex}))

    assert body["error"]["code"] == "invalidmeasurement"
    # BK-111 PROV-O chain: the refusal leaf is chain-complete (fail-closed).
    assert :ok = Smalt.Powl2.Andon.verify_ntriples(Smalt.Powl2.Andon.ntriples(andon))
    assert andon.json_ld =~ "andon:RefusalReceipt"
    assert andon.rule_id == "maa_attestation_refusal"
  end

  @tag :smalt_internal
  test "replayed nonce -> typed nonceReplay refusal + andon leaf; fresh nonce passes" do
    runtime = %{"x-ms-measurement" => @measurement_hex, "nonce" => "az2-nonce-1"}

    assert {:ok, _, _} = Maa.attest("SevSnpVM", runtime_data(runtime))

    assert {:error, 400, body, andon} = Maa.attest("SevSnpVM", runtime_data(runtime))
    assert body["error"]["code"] == "nonceReplay"
    assert andon.rule_id == "maa_nonce_replay"
    assert :ok = Smalt.Powl2.Andon.verify_ntriples(Smalt.Powl2.Andon.ntriples(andon))
  end

  @tag :smalt_internal
  test "MAA policy grammar: authorization gates; issuancerules derive claims" do
    policy = Maa.default_policy()

    # Issuance leg: the claims the token carries come from issuancerules.
    assert {:ok, issued} =
             Maa.evaluate_policy(policy, %{
               "type" => "SevSnpVM",
               "x-ms-measurement" => @measurement_hex
             })

    assert issued["type"] == "sevsnpvm"
    assert issued["x-ms-isolation-tee"] == "AMD-SEV-SNP"

    # Authorization refusal leg: wrong TEE family -> typed policy refusal.
    assert {:error, {:policy_refusal, "authorization_denied:type"}} =
             Maa.evaluate_policy(policy, %{"type" => "SgxIntelSdk", "x-ms-measurement" => @measurement_hex})

    # Fail-closed: a policy with no authorizationrules section refuses typed.
    assert {:error, {:policy_refusal, "missing_section:authorizationrules"}} =
             Maa.evaluate_policy("version=1.0; issuancerules { c:[a==\"b\"] => issue(c=\"d\"); };", %{
               "a" => "b"
             })

    # Unroutable TEE through the attest face -> typed refusal.
    assert {:error, 400, _, _} = Maa.attest("Tpm", runtime_data(%{"x-ms-measurement" => @measurement_hex}))
  end

  @tag :smalt_internal
  test "SKR witness: valid measurement JWT releases; tampered measurement refuses 403" do
    key = "az2-skr-" <> Integer.to_string(System.unique_integer([:positive]))

    Store.put(:smalt_vault_keys, key, %{
      "kty" => "oct-HSM",
      "release_policy" => %{
        "allOf" => [
          %{"claim" => "x-ms-compliance-status", "condition" => "equals", "value" => "azure-compliant-cvm"}
        ]
      }
    })

    # A structurally valid quote over a DIFFERENT measurement (valid token).
    tampered = :crypto.strong_rand_bytes(32)
    tampered_hex = Base.encode16(tampered, case: :lower)

    assert {:ok, token, _} =
             Maa.attest("SevSnpVM", runtime_data(%{"x-ms-measurement" => @measurement_hex}))

    assert {:ok, 200, body} = Maa.secure_key_release(key, token, @measurement_hex)
    assert body["attested_measurement"] == @measurement_hex

    # A token minted over a DIFFERENT measurement is a typed 403.
    assert {:ok, foreign_token, _} =
             Maa.attest("SevSnpVM", runtime_data_for(tampered, %{"x-ms-measurement" => tampered_hex}))

    assert {:error, 403, %{"error" => %{"code" => "UnauthorizedAttestation"}}} =
             Maa.secure_key_release(key, foreign_token, @measurement_hex)
  end
end
