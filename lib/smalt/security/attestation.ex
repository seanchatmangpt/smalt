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
    measurement =
      Map.get(measurement_params, "measurement") || Map.get(measurement_params, :measurement)

    # Crash-class law (lens-10): the attestation TYPE rides into the signed
    # claims and is JSON-encoded on the success path — a hostile shape (tuple/
    # integer) must be a typed 400 refusal, never a Jason.Encoder raise
    # escaping a public API whose contract is {:ok,t,c} | {:error,400,_}.
    # nil/false keep the documented default (`type || @attestation_type`).
    type = attestation_type(type)

    cond do
      type == :error ->
        {:error, 400, "attestationFailedVerdict"}

      not is_binary(measurement) or not hex64?(measurement) ->
        {:error, 400, "attestationFailedVerdict"}

      not baseline_member?(measurement) ->
        {:error, 400, "attestationFailedVerdict"}

      true ->
        # Crash-class law (lens-5): a hostile measurement_params shape (e.g. a
        # tuple value) must be a typed refusal, never an encode raise escaping
        # the attest path. Same 400 envelope as every other failed verdict.
        with {:ok, payload_hash} <- payload_hash(measurement_params) do
          now = System.system_time(:second)

          claims = %{
            "iss" => "https://smalt-attestation.local/",
            "iat" => now,
            "exp" => now + @ttl_seconds,
            "x-ms-attestation-type" => type,
            "x-ms-compliance-status" => @compliance_status,
            "x-ms-isolation-tee" => @tee_type,
            "x-ms-runtime" => %{
              "jti" => System.unique_integer([:positive]) |> to_string(),
              "client_payload_hash" => payload_hash
            }
          }

          token = ReceiptSigner.sign(claims)
          {:ok, token, claims}
        else
          {:error, :invalid_payload} -> {:error, 400, "attestationFailedVerdict"}
        end
    end
  end

  # Lens-10 totalization: binary type admitted as-is; nil/false fall back to
  # the documented default; every other shape is a typed :error refusal.
  defp attestation_type(type) when is_binary(type), do: type
  defp attestation_type(nil), do: @attestation_type
  defp attestation_type(false), do: @attestation_type
  defp attestation_type(_), do: :error

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

  # Total: canonicalization + encode of hostile shapes (tuple keys/values)
  # raises; the attest path must refuse typed, never raise (lens-5).
  defp payload_hash(measurement_params) do
    {:ok,
     measurement_params
     |> canonical()
     |> Jason.encode!()
     |> then(&:crypto.hash(:sha256, &1))
     |> Base.encode16(case: :lower)}
  rescue
    _ -> {:error, :invalid_payload}
  end
end
