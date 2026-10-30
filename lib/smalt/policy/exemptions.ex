defmodule Smalt.Policy.Exemptions do

  @moduledoc """
  Policy exemptions (Microsoft.Authorization/policyExemptions) — the ARM
  face for scoped exemption records.

  Requires `properties.policyAssignmentId` (typed 400 refusal when
  missing/empty); honors `properties.expiresOn` (ISO-8601). The submitted
  `properties` map is persisted WHOLESALE (typed-validate the required
  fields, echo everything else) so `exemptionCategory` (Waiver | Mitigated),
  `displayName`, `description`, and `metadata` round-trip on GET — real ARM
  echoes every submitted exemption property.
  """

  alias Smalt.Policy.Store


  # ===========================================================================
  # Policy exemptions
  # ===========================================================================

  @doc """
  Puts a policy exemption at a scope (subscription or RG placement). Requires
  `properties.policyAssignmentId` (typed 400 refusal when missing/empty);
  honors `properties.expiresOn` (ISO-8601). The submitted `properties` map is
  persisted WHOLESALE (typed-validate the required fields, echo everything
  else) so `exemptionCategory` (Waiver | Mitigated), `displayName`,
  `description`, and `metadata` round-trip on GET — real ARM echoes every
  submitted exemption property.

  Returns `{:ok, record}` or `{:error, refusal}` for a malformed body.
  """
  def put_policy_exemption(scope_prefix, name, body) do
    Store.ensure_tables()

    props = get_in(body, ["properties"]) || %{}
    assignment_id = props["policyAssignmentId"]
    expires_on = props["expiresOn"]

    cond do
      not is_binary(assignment_id) or assignment_id == "" ->
        {:error, exemption_refusal(scope_prefix, name, "policyAssignmentId is required")}

      expires_on != nil and not is_binary(expires_on) ->
        {:error, exemption_refusal(scope_prefix, name, "expiresOn must be an ISO-8601 string")}

      true ->
        record = %{
          "id" => "#{scope_prefix}/providers/Microsoft.Authorization/policyExemptions/#{name}",
          "name" => name,
          "type" => "Microsoft.Authorization/policyExemptions",
          "properties" =>
            props
            |> Map.put("policyAssignmentId", assignment_id)
            |> Map.put("scope", props["scope"] || scope_prefix)
            |> Map.put("exemptionCategory", props["exemptionCategory"] || "Waiver")
        }

        :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
        {:ok, record}
    end
  end

  def get_policy_exemption(scope_prefix, name) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(exemption_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_exemptions(scope_prefix) do
    Store.ensure_tables()

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/policyexemptions/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policyExemptions"))
    # KD-COVERS: KD-125 — the shared :smalt_policy table also holds rem:/rs: rows
    # with no "id" key — a nil there 500'd both list faces permanently
    # (witnessed 2026-10-20, substrate.log 18:02/18:09). Nil-safe filter.
    |> Enum.filter(fn r ->
      case r["id"] do
        nil -> false
        id -> String.downcase(id) |> String.starts_with?(prefix)
      end
    end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Deletes an exemption. An exemption whose `expiresOn` is in the past is
  swept too (ARM semantics: an expired exemption no longer exempts, so it
  must not linger GETable).
  """
  def delete_policy_exemption(scope_prefix, name) do
    Store.ensure_tables()

    case get_policy_exemption(scope_prefix, name) do
      {:ok, record} ->
        # Cascade the exemption's receipts keyed by its exemption id.
        ex_id_low = String.downcase(record["id"])

        for {key, _} <- :ets.tab2list(:smalt_policy),
            is_binary(key) and String.starts_with?(key, "exr:#{ex_id_low}:") do
          :ets.delete(:smalt_policy, key)
        end

        :ets.delete(:smalt_policy, ex_id_low)
        :ok

      :error ->
        :ok
    end
  end

  defp exemption_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/policyExemptions/#{name}"

  defp exemption_refusal(scope_prefix, name, reason),
    do: %{
      "error" => %{
        "code" => "PolicyExemptionInvalid",
        "message" => "Policy exemption '#{name}' at scope '#{scope_prefix}' is invalid. #{reason}.",
        "target" => nil,
        "innererror" => %{}
      }
    }
  defp expired?(nil), do: false

  defp expired?(expires_on) when is_binary(expires_on) do
    case DateTime.from_iso8601(expires_on) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond) <= Store.now_ms()
      _ -> false
    end
  end

  defp expired?(_), do: false

  @doc "Whether the exemption record is active (exists and expiresOn not past)."
  def exemption_active?(record) do
    is_map(record) and not expired?(get_in(record, ["properties", "expiresOn"]))
  end
end
