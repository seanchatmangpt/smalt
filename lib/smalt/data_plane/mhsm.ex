defmodule Smalt.DataPlane.MHSM do
  @moduledoc """
  Azure Managed HSM **key release policy face** over the existing KV wire
  (AZ-4, v26.10.22).

  Real MHSM shape (Azure Managed HSM REST API — key release policy, KeyBundle
  `release_policy` member; docs: "Key Vault: Managed HSM key release policy,
  `KeyReleasePolicy` in the
  `application/vnd.microsoft.azure.keyvault.keys.releasepolicy+json;
  charset=utf-8` grammar" — https://learn.microsoft.com/en-us/rest/api/keyvault/
  keys/create-key/create-key and the MHSM secure-key-release how-to):

  - keys created under a `/managedHsm` pool carry `release_policy`
    (`dataExecution`, `exportable`, `anyOf`/`assertions`) and HSM-backed
    `key_type` (`rsa-HSM`, `oct-HSM` — already accepted by
    `Smalt.Egress.KvRoutes.jwk_for_kty/4`);
  - `GET /keys/{name}` returns the policy verbatim (KvRoutes R111 face);
  - RELEASE requires the assertion match: an attestation token whose claims do
    not satisfy the policy is refused with the typed MHSM error
    **KeyReleasePolicyViolation** (403).

  Loopback reality, typed honestly: **FIPS-level hardware isolation is
  UNSUPPORTED** — no HSM silicon is present at loopback and a real MHSM pool
  cannot be provisioned here (falsifier: a real MHSM pool cannot be provisioned
  on this machine). The POLICY face is protocol-real: creation, storage, GET
  echo, and assertion evaluation are all enforced on the release path.

  Policy grammar accepted (Azure anyOf/allOf/claim/equals + smalt
  `allowed_operations`, mirroring `KvRoutes.validate_release_policy/1`):

  - `anyOf` — allow iff AT LEAST ONE entry matches (OR). Entries are assertions
    or nested groups (`allOf`).
  - `allOf` / `assertions` — allow iff ALL assertions match (AND).
  - assertion: `{"claim": path, "condition": "equals" | "contains",
    "value": term}`. Unknown conditions refuse (fail-closed, never allow).
  - claim resolution: top-level token claim precedence, falling back to the
    nested MAA `x-ms-isolation-tee` object (same traversal as SKR's
    `claim_value/2`).
  - ops-only policy (`allowed_operations` / `allowedOperations`, no claim
    assertions) imposes no claim constraints — :ok.
  - degenerate empty constraint sets (`anyOf: []`, `allOf: []`,
    `assertions: []`) refuse with 403 KeyReleasePolicyViolation (fail-closed:
    an empty set is vacuously nothing-matches, never an allow-all).
  - malformed constraint types (non-list `anyOf`/`allOf`/`assertions`) refuse
    with 403 KeyReleasePolicyViolation (fail-closed — EXPL5-T1).

  Errors (MHSM/KV error envelope): `403 KeyReleasePolicyViolation` (assertion
  mismatch or unresolvable assertion claim — fail-closed), `400
  KeyNotExportable` (policy-less key — the RELEASE face requires a policy;
  owned by `Smalt.DataPlane.SKR.fetch_exportable/1`).
  """

  alias Smalt.Store

  @violation_code "KeyReleasePolicyViolation"
  @tee_claim "x-ms-isolation-tee"

  @doc """
  Evaluate a release policy against verified attestation token claims.
  Returns `:ok` when the policy admits the release, or
  `{:error, 403, body}` with the typed `KeyReleasePolicyViolation` envelope.
  Fail-closed: a structurally unresolvable policy or an unresolvable claim
  refuses — never allows.
  """
  @spec evaluate_policy(map() | nil, map()) :: :ok | {:error, 403, map()}
  def evaluate_policy(nil, _claims), do: {:error, 403, violation("policy is required on RELEASE (policy-required face)")}

  def evaluate_policy(policy, claims) when is_map(policy) and is_map(claims) do
    case policy_groups(policy) do
      # ops-only policy: no claim-constraint keys at all → no claim constraint.
      :ops_only ->
        :ok

      # EXPL-3-T3: a degenerate empty constraint set (anyOf: [], allOf: [],
      # assertions: []) is vacuously nothing-matches — refuse (fail-closed),
      # never an unconstrained allow-all.
      {:refuse, reason} ->
        {:error, 403, violation(reason)}

      {:groups, groups} ->
        if Enum.any?(groups, &group_matches?(&1, claims)),
          do: :ok,
          else: {:error, 403, violation("release policy assertions not satisfied by attestation token claims")}
    end
  end

  def evaluate_policy(_policy, _claims), do: {:error, 403, violation("release policy must be a JSON object")}

  # The OR set: top-level anyOf entries; otherwise a single allOf group of the
  # top-level assertions/allOf/assertions list. Returns :ops_only when NO
  # claim-constraint key is present, {:refuse, reason} for a degenerate empty
  # constraint set, {:groups, list} otherwise.
  defp policy_groups(%{"anyOf" => any_of}) when is_list(any_of) do
    case any_of do
      [] -> {:refuse, "release policy anyOf is empty (no assertion can match — vacuous allow-all refused)"}
      entries -> {:groups, entries}
    end
  end

  # EXPL5-T1: a non-list anyOf (string/map/number) is a malformed policy, not an
  # ops-only policy — refuse (fail-closed), never an unconstrained allow-all.
  defp policy_groups(%{"anyOf" => other}) do
    {:refuse, "release policy anyOf must be a list, got: #{inspect(other)}"}
  end

  defp policy_groups(policy) do
    has_all? = Map.has_key?(policy, "allOf")
    has_assertions? = Map.has_key?(policy, "assertions")

    # EXPL5-T1: non-list allOf/assertions are malformed — refuse (fail-closed)
    # rather than List.wrap-coercing them into a constraint group.
    cond do
      has_all? and not is_list(policy["allOf"]) ->
        {:refuse, "release policy allOf must be a list, got: #{inspect(policy["allOf"])}"}

      has_assertions? and not is_list(policy["assertions"]) ->
        {:refuse, "release policy assertions must be a list, got: #{inspect(policy["assertions"])}"}

      true ->
        policy_groups_list(policy, has_all?, has_assertions?)
    end
  end

  defp policy_groups_list(policy, has_all?, has_assertions?) do
    if has_all? or has_assertions? do
      assertions =
        (List.wrap(policy["allOf"]) ++ List.wrap(policy["assertions"]))
        |> Enum.reject(&is_nil/1)

      case assertions do
        [] ->
          {:refuse, "release policy allOf/assertions is an empty constraint set — vacuous allow-all refused"}

        _ ->
          all =
            Enum.flat_map(assertions, fn
              %{} = a -> List.wrap(a["allOf"]) ++ List.wrap(a["assertions"]) ++ [a]
              other -> [other]
            end)

          {:groups, [all]}
      end
    else
      :ops_only
    end
  end

  # A group is a list of assertions (allOf). A single assertion map is a
  # one-element group.
  defp group_matches?(group, claims) when is_list(group),
    do: Enum.all?(group, &assertion_matches?(&1, claims))

  defp group_matches?(%{} = assertion, claims), do: assertion_matches?(assertion, claims)

  defp group_matches?(_malformed, _claims),
    do: false

  defp assertion_matches?(%{"claim" => claim, "condition" => condition} = assertion, claims)
       when is_binary(claim) do
    actual = claim_value(claims, claim)
    expected = assertion["value"]

    case condition do
      "equals" -> actual != nil and actual == expected
      "contains" -> contains?(actual, expected)
      _ -> false
    end
  end

  defp assertion_matches?(%{"claim" => _}, _claims), do: false
  defp assertion_matches?(_malformed, _claims), do: false

  defp contains?(actual, expected) when is_binary(actual) and is_binary(expected),
    do: String.contains?(actual, expected)

  defp contains?(actual, expected) when is_list(actual), do: expected in actual
  # An unresolvable/nil actual under contains is a mismatch (fail-closed).
  defp contains?(_actual, _expected), do: false

  # Nested MAA form: top-level precedence, fallback to x-ms-isolation-tee
  # (same traversal as Smalt.DataPlane.SKR.claim_value/2 — canonical accessor).
  defp claim_value(claims, key) do
    claims[key] ||
      case claims[@tee_claim] do
        %{} = tee -> tee[key]
        _ -> nil
      end
  end

  defp violation(message) do
    %{
      "error" => %{
        "code" => @violation_code,
        "message" => "Secure Key Release refused: #{message}"
      }
    }
  end

  # Store accessor for the court: the raw policy stored on the key row.
  @doc false
  def stored_policy(name) do
    case Store.get(:smalt_vault_keys, name) do
      {:ok, %{"release_policy" => policy}} -> policy
      :error -> :error
    end
  end
end
