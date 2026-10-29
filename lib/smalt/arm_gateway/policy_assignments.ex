defmodule Smalt.ArmGateway.PolicyAssignments do
  @moduledoc """
  ARM policy-assignments read surface (CONVERGENCE lane V10, upstream smalt).

  `GET /subscriptions/{sub}/providers/Microsoft.Authorization/policyAssignments`
  and `GET /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Authorization/policyAssignments`
  return the documented ARM list envelope
  `%{"value" => [assignment, ...]}` (200, no nextLink at seed scale), where
  each assignment carries `id` / `name` / `type` =
  `"Microsoft.Authorization/policyAssignments"` and `properties` =
  `{policyDefinitionId, enforcementMode, scope}` — the exact projection
  `Smalt.Policy.put_policy_assignment/3` persists.

  ## Seeded classes (mirrors athena's encoded preflight courts)

  The two classes the athena preflight
  (`infra/terraform/sovereign-policy-map.json` `requiredTags` /
  `locationAllowlist`, exercised by `playground/test/az-policy-preflight.gates.spec.ts`
  courts 2a/2b) encode as deployment-map facts are seeded here as real ARM
  assignments, so the E2 preflight map validates against a live read surface:

    * `required-tags` — enforcementMode `Default` (the audit-deny law: an
      untagged resource is denied at request time, athena court 2a),
      policyDefinitionId pinned to the required-tags definition, parameters
      carrying the athena required tag keys (`managed-by`, `sovereign`).
    * `location-allowlist` — enforcementMode `Default` (athena court 2b:
      a location outside the allowlist is denied), policyDefinitionId pinned
      to the location-allowlist definition, parameters carrying the athena
      allowlist (the 8-US-region set in the sovereign map).

  Both classes are seeded at BOTH scopes (subscription scope and the
  `rg-seed` resource-group scope) so each list face validates the classes
  independently; a re-seed is a no-op (idempotent ets insert keyed on the
  assignment id). An unknown scope has no rows under its prefix, so its list
  face is the documented empty envelope `%{"value" => []}` — never a 404.

  Wiring posture ("wire what exists, seed the rest deterministically", same
  as `Smalt.ArmGateway.CostManagement`): the router's existing list routes
  already read `Smalt.Policy.list_policy_assignments/1`, so seeding is a
  deterministic write into the SAME `:smalt_policy` table the routes read —
  no router coupling, no I/O.
  """

  alias Smalt.Policy

  @seed_rg "rg-seed"

  # The two athena-encoded classes, as ARM assignment seed laws. `parameters`
  # mirror the sovereign-policy-map facts; `put_policy_assignment/3` persists
  # policyDefinitionId + enforcementMode + scope (the documented read shape),
  # so the parameters travel in the seed body and the class NAME travels on
  # the wire via the policyDefinitionId.
  @classes [
    %{
      name: "required-tags",
      enforcement_mode: "Default",
      parameters: %{
        "listOfTagKeys" => %{"value" => ["managed-by", "sovereign"]}
      }
    },
    %{
      name: "location-allowlist",
      enforcement_mode: "Default",
      parameters: %{
        "listOfAllowedLocations" => %{
          "value" => [
            "eastus",
            "eastus2",
            "westus2",
            "westus3",
            "centralus",
            "northcentralus",
            "southcentralus",
            "westcentralus"
          ]
        }
      }
    }
  ]

  @doc "The seeded policy classes (name, enforcementMode, parameters)."
  @spec classes :: [map()]
  def classes, do: @classes

  @doc "The resource-group scope the seed places its RG-scope rows at."
  @spec seed_rg :: String.t()
  def seed_rg, do: @seed_rg

  @doc """
  Deterministic seed: places the two athena-encoded classes at subscription
  scope AND at the `rg-seed` resource-group scope of `sub_id`. Idempotent —
  a re-seed overwrites the same assignment ids with identical content.
  Returns the count of assignment rows written (2 classes x 2 scopes = 4).
  """
  @spec seed(String.t()) :: non_neg_integer()
  def seed(sub_id) when is_binary(sub_id) do
    Enum.reduce(@classes, 0, fn class, n ->
      Policy.put_policy_assignment(
        "/subscriptions/#{sub_id}",
        class.name,
        seed_body(sub_id, nil, class)
      )

      Policy.put_policy_assignment(
        "/subscriptions/#{sub_id}/resourceGroups/#{@seed_rg}",
        class.name,
        seed_body(sub_id, @seed_rg, class)
      )

      n + 2
    end)
  end

  @doc """
  The subscription-scope list face body: the documented ARM list envelope
  `%{"value" => [assignment, ...]}`, sorted by id for a stable envelope.
  Seeding is NOT implicit — callers seed explicitly (`seed/1`), matching the
  router routes that read the store directly.
  """
  @spec list_subscriptions_scope(String.t()) :: map()
  def list_subscriptions_scope(sub_id) do
    %{"value" => Policy.list_policy_assignments("/subscriptions/#{sub_id}")}
  end

  @doc """
  The RG-scope list face body for `sub_id`/`rg`. Unknown scope -> the
  documented empty envelope `%{"value" => []}`.
  """
  @spec list_resource_groups_scope(String.t(), String.t()) :: map()
  def list_resource_groups_scope(sub_id, rg) do
    %{"value" => Policy.list_policy_assignments("/subscriptions/#{sub_id}/resourceGroups/#{rg}")}
  end

  # put_policy_assignment derives the record from (scope, name, body) — the
  # scope is the placement, never client text — so the seed body carries only
  # policyDefinitionId, enforcementMode and parameters. `rg` is accepted for
  # call-site symmetry and unused for the same reason.
  defp seed_body(_sub_id, _rg, class) do
    %{
      "properties" => %{
        "policyDefinitionId" =>
          "/providers/Microsoft.Authorization/policyDefinitions/#{class.name}",
        "enforcementMode" => class.enforcement_mode,
        "parameters" => class.parameters
      }
    }
  end
end
