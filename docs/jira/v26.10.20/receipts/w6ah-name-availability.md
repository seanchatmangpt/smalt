# w6ah — CheckNameAvailability Faces (close-out w6ah2)

- **Subject**: `lib/smalt/arm/name_availability.ex` (wave-6 lane w6ah, landed but unwitnessed at the disk wall)
- **Standing**: ALIVE (module tier; wire mount is `check_wire/1`, staged for the post-split router patch)
- **Context**: full

## What the witness ran

`MIX_BUILD_ROOT=_build-lane-w6ah2 MIX_ENV=test mix run --no-start tmp/w6ah_witness.exs` — module-direct over real `Smalt.Store` (real seeded storage-account row in `:smalt_resources`), Chicago final-state assertions, zero mocks, zero `Process.sleep` (the script's one 50 ms settle sits at top-of-script in tmp scratch, not under test/ — noted for the sleep-gate scan scope which does not scan tmp/).

## Real output (re-run after one in-lane fix)

```
=== w6ah CheckNameAvailability witness ===
leg1: {:LEG1_EXISTING_ACCT, {:error, {:already_exists, "The storage account 'w6ahacct01' is already taken."}}}
leg2: {:LEG2_INVALID_ACCT, {:error, {:invalid, "The storage account name is invalid. Storage account names must be 3-24 characters and use numbers and lower-case letters only."}}}
leg3: {:LEG3_AVAILABLE_ACCT, {:ok, :name_available}}
leg4: {:LEG4_INVALID_VAULT, {:error, {:invalid, "Vault name is invalid: must be 3-24 chars, begin with a letter, end with letter or digit, alnum and hyphen only."}}}
leg5: {:LEG5_AVAILABLE_VAULT, {:ok, :name_available}}
leg7: {:LEG7_ZONE_AVAILABLE, {:ok, :name_available}}
leg8: {:LEG8_UNSUPPORTED, {:error, :unsupported_type}}
W6AH WITNESS: ALL FACES OK
EXIT=0
```

(Legs 6 and 9 are assert-only by design — web rules and wire shape; they throw on mismatch, silent on pass.)

## In-lane fix (close-out)

- `normalize_type/1` was missing the `dnsZone` → `Microsoft.Network/dnsZones` alias its three sibling types carry. One additive line (`name_availability.ex:103`); witness went red→green on leg 7 with no other change — the non-vacuity proof.

## Per-leg verdicts

| leg | face | verdict |
|---|---|---|
| 1 | existing storage account → AlreadyExists | PASS (real Store uniqueness scan) |
| 2 | uppercase storage-account name → Invalid | PASS |
| 3 | valid unique → name_available | PASS |
| 4 | vault rule violation → Invalid | PASS |
| 5 | valid vault unique → available | PASS |
| 6 | web 1-60 rules | PASS (assert-only) |
| 7 | dnsZone alias → available (fallback path; Dns module not loaded in isolation) | PASS post-fix |
| 8 | unknown type → `:unsupported_type` | PASS |
| 9 | wire shape AlreadyExists/available | PASS (assert-only) |

## Falsifier

Green under a broken per-type rule (e.g. uppercase storage-account names admitted, or unknown-type legs returning available) would be vacuous. Re-run: `MIX_BUILD_ROOT=_build-lane-w6ah2 MIX_ENV=test mix run --no-start tmp/w6ah_witness.exs`.

## Notes

- Standalone `elixirc` of the module compiles clean; the full-tree compile in this run generated the app with pre-existing warnings in `Smalt.Egress.CosmosRoutes.do_match/4` (w6R split surface, sibling-owned, not this lane's file).
- No git operations. Build root `_build-lane-w6ah2` left for coordinator `lane-clean`.
