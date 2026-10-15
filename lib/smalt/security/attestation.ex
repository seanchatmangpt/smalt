defmodule Smalt.Security.Attestation do
  @moduledoc """
  Microsoft Azure Attestation (MAA) service emulator
  (`Microsoft.Attestation/attestationProviders`).

  Issues RS256-signed JWT attestation tokens with `azure-compliant-cvm` and
  `sevsnpvm` claims, but only for measurements present in the configured
  baseline (`Application.get_env(:smalt, :maa_measurement_baseline)` or
  `Smalt.Store` rows in `:smalt_attestation_baseline`).
  """

  alias Smalt.Security.ReceiptSigner

  @compliance_status "azure-compliant-cvm"
  @attestation_type "sevsnpvm"
  @tee_type "AMD-SEV-SNP"
  @ttl_seconds 7200

  @doc """
  Evaluates quote `measurement_params` (expects a hex64 `"measurement"` key)
  against the baseline and issues a signed MAA token.

  Returns `{:ok, token, claims}` when the measurement is attested, or
  `{:error, 400, "attestationFailedVerdict"}` when it is not in the baseline.
  """
  @spec attest_enclave(map(), String.t() | nil) ::
          {:ok, String.t(), map()} | {:error, 400, String.t()}
  def attest_enclave(measurement_params, type \\ @attestation_type)
      when is_map(measurement_params) do
    measurement = Map.get(measurement_params, "measurement") || Map.get(measurement_params, :measurement)

    cond do
      not is_binary(measurement) or not hex64?(measurement) ->
        {:error, 400, "attestationFailedVerdict"}

      not baseline_member?(measurement) ->
        {:error, 400, "attestationFailedVerdict"}

      true ->
        now = System.system_time(:second)

        claims = %{
          "iss" => "https://smalt-attestation.local/",
          "iat" => now,
          "exp" => now + @ttl_seconds,
          "x-ms-attestation-type" => type || @attestation_type,
          "x-ms-compliance-status" => @compliance_status,
          "x-ms-isolation-tee" => @tee_type,
          "x-ms-runtime" => %{
            "jti" => System.unique_integer([:positive]) |> to_string(),
            "client_payload_hash" =>
              measurement_params
              |> canonical()
              |> Jason.encode!()
              |> then(&:crypto.hash(:sha256, &1))
              |> Base.encode16(case: :lower)
          }
        }

        token = ReceiptSigner.sign(claims)
        {:ok, token, claims}
    end
  end

  @doc """
  Verifies an attestation token: RS256 signature only (alg-confusion safe) plus
  `exp` freshness. Returns `{:ok, claims}` or `{:error, reason}`.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term}
  def verify_token(token), do: ReceiptSigner.verify_token(token)

  ## Baseline

  defp baseline_member?(measurement) do
    config_member?(measurement) or store_member?(measurement)
  end

  defp config_member?(measurement) do
    case Application.get_env(:smalt, :maa_measurement_baseline) do
      nil -> false
      baseline -> Enum.member?(baseline_list(baseline), measurement)
    end
  end

  defp baseline_list(%{} = map), do: Map.values(map)
  defp baseline_list(list) when is_list(list), do: list
  defp baseline_list(single) when is_binary(single), do: [single]
  defp baseline_list(_), do: []

  defp store_member?(measurement) do
    case Smalt.Store.get(:smalt_attestation_baseline, measurement) do
      {:ok, _} ->
        true

      :error ->
        # Baseline rows may also be stored under arbitrary keys with the
        # measurement as a value; scan them before declaring failure.
        Smalt.Store.keys(:smalt_attestation_baseline)
        |> Enum.any?(fn key ->
          match?({:ok, ^measurement}, Smalt.Store.get(:smalt_attestation_baseline, key)) or
            match?({:ok, %{^measurement => _}}, Smalt.Store.get(:smalt_attestation_baseline, key))
        end)
    end
  end

  defp hex64?(s) do
    is_binary(s) and byte_size(s) == 64 and Regex.match?(~r/^[0-9a-fA-F]{64}$/, s)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Map.new()
  end

  defp canonical(other), do: other
end
