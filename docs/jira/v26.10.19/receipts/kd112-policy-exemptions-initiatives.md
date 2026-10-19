# Receipt: lane-pol — KD-112 policy exemptions + initiatives (policySetDefinitions)

Standing: **PASS** (witnessed, 2026-10-19)
Context: full
Lane: policy.ex exclusive owner; router routes documented for coordinator wiring (X-ARR lane pattern).

## Subject

- `lib/smalt/policy.ex` (only file touched; +320/-16 vs HEAD, plus fix-forward edits)
- Build: `MIX_BUILD_ROOT=_build-lane-pol`

## What landed

1. **policyExemptions CRUD** — `put/get/list/delete_policy_exemption(scope_prefix, name, body)`.
   Record shape mirrors ARM: id
   `{scope}/providers/Microsoft.Authorization/policyExemptions/{name}`, type
   `Microsoft.Authorization/policyExemptions`, properties `{policyAssignmentId, scope,
   expiresOn, category}`. `put` returns `{:ok, record}` or `{:error, refusal}`; refusal
   shape follows the module's PolicyViolation envelope (code `PolicyExemptionInvalid`,
   message, target, innererror).
2. **Exemption-aware enforcement** — `enforce/3`: when a deny/audit condition matches and an
   ACTIVE (non-expired) exemption exists for the assignment whose scope covers the resource,
   the deny is skipped and a `smaltReceiptType: "policyExemption"` receipt is recorded keyed
   `exr:<assignment>:<resource>:<definition>`. Expired exemptions do not exempt.
3. **Initiatives (policySetDefinitions)** — `put/get/list_policy_set_definition(sub_id, name,
   body)` with member `policyDefinitions` references; refusal `PolicySetDefinitionInvalid`
   for empty/non-member-listed bodies. `evaluate_assignment/2` now resolves an assignment's
   `policyDefinitionId` through the set: members are iterated, worst-effect wins (deny >
   audit, then sorted assignment id). Unknown/member-missing definitions degrade to no-rule.
4. **Clock seam** — `Smalt.Policy.now_ms/0` (public), overridable via
   `Application.put_env(:smalt, :policy_now_ms, ms)`; `exemption_active?/1` public for tests.

## Witness

Script: `/tmp/pol_witness.exs` — `MIX_BUILD_ROOT=_build-lane-pol mix run /tmp/pol_witness.exs`

Real output (abridged markers, all as-specified):

```
1.enforce-no-exemption: {:deny, ...PolicyViolation...pa-west...}
2.put-exemption: "/subscriptions/sub-1/.../policyExemptions/ex-1"
2.enforce-with-exemption: :ok
2.exemption-receipts: [%{"exempted" => true, ... "smaltReceiptType" => "policyExemption"}]
3.enforce-expired-exemption: {:deny, ...PolicyViolation...}
4.malformed-exemption: {:error, %{"error" => %{"code" => "PolicyExemptionInvalid", ...}}}
5.malformed-set: {:error, %{"code" => "PolicySetDefinitionInvalid", ...}}
6.put-initiative: ".../policySetDefinitions/init-1"
6.assignment-to-initiative: ".../policyAssignments/pa-init"
6.enforce-west-vm(deny via deny-west): {:deny, ...}
6.enforce-east-vm(deny via deny-east): {:deny, ...}
6.enforce-central-vm(ok): :ok
7.get-exemption: :ok | 7.list-exemptions: ["ex-1"] | 7.after-delete-get: :error
7.get-set-definition: :ok | 7.list-set-definitions: ["init-1"]
```

Bug fixed forward during witness: `evaluate_rule` initially returned string effects
(`"audit"`/`"deny"`) where `enforce/3` matches atom tuples — witnessed as deny silent-:ok,
fixed to `:audit`/`:deny`, re-witnessed green. A second defect (Access.get on binary in
`record_receipt` — verdict tuple carried def_id where enforce expects the assignment map)
surfaced in run 2 and was fixed the same way (verdicts normalized to `{effect, assignment,
reason}`).

## Compile-freeze disclosure

Shared `lib/` compile froze twice on `lib/smalt/messaging/event_grid.ex` (another lane's
DLQ refactor mid-flight; `name` param then `dlq_step/4`). No unblock fix was applied by
this lane — the owning lane landed its own fixes within the SLA; I poll-compiled until
green and ran the witness on the first green compile.

## Verification

- `MIX_BUILD_ROOT=_build-lane-pol mix compile --warnings-as-errors`: 0 policy.ex warnings
  (grep count 0).
- No pre-existing policy test file exists (legacy suite deleted in 64f6099); witness script
  is the court. App boots clean (Bandit 9443/8443/9444/5672/5673/9545 in witness log).

## Route-table additions for the coordinator (NOT yet wired into router.ex)

```elixir
# Policy exemptions (subscription scope AND RG scope)
put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions/:name" do
  with :ok <- check_api_version(conn, @pe_type) do
    case Policy.put_policy_exemption("/subscriptions/#{sub_id}", name, conn.body_params) do
      {:ok, record} -> send_json(conn, 201, Jason.encode!(record))
      {:error, body} -> send_json(conn, 400, Jason.encode!(body))
    end
  else
    {:respond, conn} -> conn
  end
end

get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions/:name" ...
  Policy.get_policy_exemption("/subscriptions/#{sub_id}", name)  # {:ok,r} -> 200; :error -> 404 ResourceNotFound

get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions" ...
  send_list(conn, Policy.list_policy_exemptions("/subscriptions/#{sub_id}"))

delete "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions/:name" ...
  Policy.delete_policy_exemption("/subscriptions/#{sub_id}", name); send_json(conn, 200, "")

put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyExemptions/:name" ...
  Policy.put_policy_exemption("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", name, conn.body_params)

get / delete RG-scope variants (mirror the existing policyAssignments RG routes)

# Policy set definitions (initiatives, subscription scope)
put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions/:name" do
  with :ok <- check_api_version(conn, @psd_type) do
    case Policy.put_policy_set_definition(sub_id, name, conn.body_params) do
      {:ok, record} -> send_json(conn, 201, Jason.encode!(record))
      {:error, body} -> send_json(conn, 400, Jason.encode!(body))
    end
  else
    {:respond, conn} -> conn
  end
end

get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions/:name" ...
  Policy.get_policy_set_definition(sub_id, name)  # 200 / 404 ResourceNotFound

get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions" ...
  send_list(conn, Policy.list_policy_set_definitions(sub_id))
```

Coordinator note: `@pe_type = "Microsoft.Authorization/policyExemptions"` and
`@psd_type = "Microsoft.Authorization/policySetDefinitions"` need registering for
`check_api_version/2` alongside `@pd_type`/`@pa_type` (lines ~4176 router.ex).

## Falsifier

Re-run `/tmp/pol_witness.exs` — step 1/3 deny, step 2 allow+receipt, step 6 both-member
initiative denies. Any step flipping breaks the receipt.
