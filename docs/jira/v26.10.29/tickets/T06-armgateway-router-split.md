# T06 — Split `Smalt.ArmGateway.Router` (8428 lines)

- window: v26.10.29 · status: QUEUED · class: decomposition (priority 1)

## Why

Largest file in the tree (8428 lines, one plug module). Elixir best
practice: a plug router should be a thin dispatch surface, with per-resource
logic in focused modules. The file already has internal section fences —
the split follows the seams that exist.

## Split plan (seam-following, behavior-preserving)

Extract per-route-family plug modules behind a front plug that delegates:

- `ArmGateway.Plug.SubscriptionRouter` (subscriptions/RGs/tagNames/tenants)
- `ArmGateway.Plug.ResourceProviders` (providers, policy*,
  roleAssignments, locks, exemptions)
- `ArmGateway Engines` — pull the big private engines (LRO, policy engine,
  registry glue) into `ArmGateway.Engine.*` modules
- `ArmGateway.Plug.OidcSts` (the `/oauth2` + discovery faces)
- `ArmGateway.Plug.Metadata` (metadata/identity endpoint)

Front `Router.call/2` keeps: auth_mode plug, rate limit, api-version gate —
then `Plug.Cascade`-style delegation with the existing typed 404 fallback.

## Constraints

- Wire bytes byte-identical: every extracted module keeps the same typed
  error envelopes; the existing courts (test/internal + integration) are
  the regression gate — no test edits, only green reruns.
- No hand-edits to generated files (registry.ex etc. are generator-owned).
- Elixir idiom: `defdelegate`/behaviour-based dispatch, no macros that
  hide control flow; each extracted module gets a focused @moduledoc.
