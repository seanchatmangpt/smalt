defmodule Smalt.Policy do
  @moduledoc """
  80/20 Azure Policy + RBAC engine for the ARM gateway.

  Facade over the concern modules (T10 split, L13):

  - `Smalt.Policy.Store` — lazy shadow-table lifecycle (heir to :init) + clock
  - `Smalt.Policy.Assignments` — role definitions/assignments + policy assignments
  - `Smalt.Policy.Eval` — locks, definitions, enforcement engine
  - `Smalt.Policy.Exemptions` — policyExemptions face
  - `Smalt.Policy.Remediations` — policyRemediations face

  Two ETS tables (same fail-closed conventions as Smalt.Store):

  - `:smalt_policy` — policy definitions (`definition:<lower id>`), policy
    assignments (`assignment:<lower id>`), and non-compliance receipts
    (`nc:<assignment id>:<resource id>`) in one :set table.
  - `:smalt_rbac` — role assignments (`ra:<lower id>`).

  Management locks (`Microsoft.Authorization/locks`, KD-113 leg b) and policy
  exemptions share the `:smalt_policy` table, discriminated by `type`.
  Policy remediations (`Microsoft.Authorization/policyRemediations`) live in
  the same table: PUT/GET/LIST/DELETE at sub+RG scope, plus
  `trigger_policy_remediation/2`, which re-runs the assignment evaluation per
  resourceId at trigger time and records compliant-after / still-violating
  receipts. `enforce/3` snapshots each evaluated record ("rs:" rows) so a
  trigger re-evaluates the live resource state.

  RBAC enforcement: `authorize?/3` + `authorize?/4` resolve assignment scope
  prefixes (subscription > RG > resource) with inheritance; built-in role
  GUIDs map to verb sets via `role_verbs/1`. `lock_blocks?/2` gates verbs
  against CanNotDelete/ReadOnly lock records; `enforce/3` checks locks before
  policy deny evaluation and refuses with a 409-class ScopeLocked envelope.

  Role definitions are BUILT-IN (Owner / Contributor / Reader, well-known
  Azure GUIDs) and served deterministically — never stored, never fabricated
  per-caller.

  Enforcement: `enforce/3` evaluates every policy assignment whose scope is
  the resource's RG scope or its subscription scope (ARM scope-prefix
  semantics) on the generic resource PUT path. A `deny` effect refuses the
  PUT with a typed 400 PolicyViolation envelope; an `audit` effect records
  non-compliance without blocking. Both effects write a non-compliance
  receipt; a compliant PUT clears prior receipts for that resource.

  Supported 80/20 policyRule conditions (nestable via allof/anyof):
  equals / notEquals / in / notIn / containsKey over fields `location`,
  `name`, `type`, `tags` (containsKey), `tags.<key>`, and dotted record
  fields (e.g. `sku.size`).
  """

  alias Smalt.Policy.{Assignments, Eval, Exemptions, Remediations, Store}

  # Store
  defdelegate reset_for_test, to: Store
  defdelegate now_ms, to: Store

  # Assignments (RBAC + policy assignments)
  defdelegate role_definition(scope_prefix, name_or_guid), to: Assignments
  defdelegate put_role_assignment(scope_prefix, name, body), to: Assignments
  defdelegate get_role_assignment(scope_prefix, name), to: Assignments
  defdelegate delete_role_assignment(scope_prefix, name), to: Assignments
  defdelegate list_role_assignments(scope_prefix), to: Assignments
  defdelegate role_verbs(role_name), to: Assignments
  defdelegate authorize?(principal_id, role_definition_id, resource_id), to: Assignments
  defdelegate authorize?(principal_id, role_definition_id, resource_id, verb), to: Assignments
  defdelegate put_policy_assignment(scope_prefix, name, body), to: Assignments
  defdelegate get_policy_assignment(scope_prefix, name), to: Assignments
  defdelegate delete_policy_assignment(scope_prefix, name), to: Assignments
  defdelegate list_policy_assignments(scope_prefix), to: Assignments

  # Eval (locks + definitions + enforcement)
  defdelegate put_lock(scope_prefix, name, body), to: Eval
  defdelegate get_lock(scope_prefix, name), to: Eval
  defdelegate delete_lock(scope_prefix, name), to: Eval
  defdelegate list_locks(scope_prefix), to: Eval
  defdelegate lock_blocks?(resource_id, verb), to: Eval
  defdelegate put_policy_definition(sub_id, name, body), to: Eval
  defdelegate get_policy_definition(sub_id, name), to: Eval
  defdelegate list_policy_definitions(sub_id), to: Eval
  defdelegate put_policy_set_definition(sub_id, name, body), to: Eval
  defdelegate get_policy_set_definition(sub_id, name), to: Eval
  defdelegate list_policy_set_definitions(sub_id), to: Eval
  defdelegate enforce(sub_id, rg_name, record), to: Eval
  defdelegate non_compliance_summary, to: Eval
  defdelegate non_compliant_resources(assignment_id), to: Eval

  # Exemptions
  defdelegate put_policy_exemption(scope_prefix, name, body), to: Exemptions
  defdelegate get_policy_exemption(scope_prefix, name), to: Exemptions
  defdelegate list_policy_exemptions(scope_prefix), to: Exemptions
  defdelegate delete_policy_exemption(scope_prefix, name), to: Exemptions
  defdelegate exemption_active?(record), to: Exemptions

  # Remediations
  defdelegate put_policy_remediation(scope_prefix, name, body), to: Remediations
  defdelegate get_policy_remediation(scope_prefix, name), to: Remediations
  defdelegate list_policy_remediations(scope_prefix), to: Remediations
  defdelegate delete_policy_remediation(scope_prefix, name), to: Remediations
  defdelegate trigger_policy_remediation(scope_prefix, name), to: Remediations
  defdelegate resource_state(resource_id), to: Remediations
end
