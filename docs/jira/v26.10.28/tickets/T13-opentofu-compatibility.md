# T-13 — OpenTofu: verified compatibility + dedicated suite

- status: CLOSED at plan tier (2026-10-28): receipt receipts/r1-t13-opentofu-plan-parity.md (tofu 1.13.2 = terraform 1.17.0, 3 to add)
- window: v26.10.28 · maps-to: Topaz v1.14 "OpenTofu — verified compatibility · dedicated test suite · integration guide" · verdict-at-open: **PARTIAL**
- size: **S** · depends-on: — · parity-leg: tofu-plan-smoke recipe

## current state (evidence)

azurerm plan-smoke is shipped (`just tf-plan-smoke`, terraform fixture
plans against the substrate). No OpenTofu-branded run or receipt exists
(map row).

## scope

1. Run the existing terraform fixture suite under the `tofu` binary
   (CI/portable recipe: `just tofu-plan-smoke`, downloading/locating tofu
   the same way the suite treats terraform).
2. Record divergences (if any) between terraform-plan and tofu-plan output
   against the substrate; fix substrate-side causes only.
3. Short integration note in the how-to tree (pointer from the map).

## non-goals

- New fixtures beyond the existing corpus (the point is transfer, not
  breadth).

## Definition of Done — the Azure developer's view

You keep your infrastructure in OpenTofu, not terraform — nothing about
smalt cares. With `tofu init` + `tofu plan` against the substrate's ARM
endpoint (the provider block from the integration note), your plan output
shows exactly the creates/changes your modules declare, identical to
running the same code against real Azure's dry-run; `tofu apply`
provisions through smalt's ARM surface and a follow-up `tofu plan` says
"No changes." The recipe runs green in CI so you never have to wonder
whether this month's tofu release still works against your local Azure.

## receipts required

`tofu plan` + `tofu apply` receipts for the fixture corpus; a
tofu-vs-terraform plan-diff receipt (expected: none).
