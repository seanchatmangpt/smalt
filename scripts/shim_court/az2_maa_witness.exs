# AZ-2 MAA shim-court witness (v26.10.22, lane az2).
#
# Usage: mix run --no-start scripts/shim_court/az2_maa_witness.exs ok|tamper
#
#   ok     -> a structurally valid SevSnpVM quote ATTESTS ({:ok, token, _})
#   tamper -> a one-byte-tampered measurement REFUSES typed 400
#             invalidmeasurement with a chain-complete andon leaf
#
# Root contract: lib/smalt/attestation/maa.ex (KD-COVERS: KD-167).
# Receipt: docs/jira/v26.10.22/receipts/az2-maa-attestation.md.

measurement = :crypto.strong_rand_bytes(32)
measurement_hex = Base.encode16(measurement, case: :lower)

runtime = Jason.encode!(%{"x-ms-measurement" => measurement_hex})
report = Base.url_encode64(<<"SMQ1", measurement::binary-size(32), byte_size(runtime)::unsigned-integer-size(32), runtime::binary>>, padding: false)

params = %{
  "report" => report,
  "runtimeData" => %{"data" => Base.encode64(runtime), "dataType" => "JSON"}
}

mode = Enum.at(System.argv(), 0)

case mode do
  "ok" ->
    case Smalt.Attestation.Maa.attest("SevSnpVM", params) do
      {:ok, token, _claims} ->
        {:ok, payload} = Smalt.Security.ReceiptSigner.verify(token)
        ^measurement_hex = payload["measurement_digest"]
        IO.puts("[AZ2-WITNESS] ok: attested, measurement_digest bound, JWS verifies")
        System.halt(0)

      other ->
        IO.puts("[AZ2-WITNESS] ok: FAILED -> #{inspect(other)}")
        System.halt(1)
    end

  "tamper" ->
    <<a, b, rest::binary>> = measurement
    tampered_hex = Base.encode16(<<a, b + 1, rest::binary>>, case: :lower)
    tampered_json = Jason.encode!(%{"x-ms-measurement" => tampered_hex})
    tampered_report = Base.url_encode64(<<"SMQ1", measurement::binary-size(32), byte_size(tampered_json)::unsigned-integer-size(32), tampered_json::binary>>, padding: false)

    tampered_params = %{
      "report" => tampered_report,
      "runtimeData" => %{"data" => Base.encode64(tampered_json), "dataType" => "JSON"}
    }

    case Smalt.Attestation.Maa.attest("SevSnpVM", tampered_params) do
      {:error, 400, %{"error" => %{"code" => "invalidmeasurement"}}, andon} ->
        :ok = Smalt.Powl2.Andon.verify_ntriples(Smalt.Powl2.Andon.ntriples(andon))
        IO.puts("[AZ2-WITNESS] tamper: refused invalidmeasurement, andon chain-complete")
        System.halt(0)

      other ->
        IO.puts("[AZ2-WITNESS] tamper: FAILED -> #{inspect(other)}")
        System.halt(1)
    end

  _ ->
    IO.puts("[AZ2-WITNESS] usage: az2_maa_witness.exs ok|tamper")
    System.halt(2)
end
