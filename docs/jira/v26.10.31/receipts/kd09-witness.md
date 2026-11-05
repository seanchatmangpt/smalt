# KD-09 witness — built-in role GUID resolution on the Policy face
Standing: ALIVE

window: v26.10.31 · status: ALIVE · Context: solo

## Subject

Fix under witness: `lib/smalt/policy/assignments.ex` (`@builtin_roles`, real Azure
built-in role definition GUIDs; `role_definition/2` resolves by name or GUID).
Fix mtime 2026-10-29 21:59. Witness receipt `docs/jira/v26.10.29/receipts/r10b-policy-split.md`
(2026-10-29 23:12) postdates the fix and lands the policy split including built-in
role definitions — flip-law satisfied (witness mtime > fix mtime).

## Fresh BEAM-side execution (2026-11-04, `mix run -e`, pinned toolchain 1.20.4-otp-29)

```elixir
{:ok, %{
  "id" => "/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
  "name" => "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
  "properties" => %{"roleName" => "Owner", "type" => "BuiltInRole"},
  "type" => "Microsoft.Authorization/roleDefinitions"
}}
```

## Resolutions witnessed (real output)

```
Owner       -> 8e3af657-a8ff-443c-a75c-2fe8c4bcb635
Contributor -> b24988ac-6180-42a0-ab88-20f7382dd24c
Reader      -> acdd72a7-3385-48ef-bd42-f606fba81ae7
"owner" (case-insensitive) -> 8e3af657-a8ff-443c-a75c-2fe8c4bcb635
GUID input b24988ac-6180-42a0-ab88-20f7382dd24c -> resolved to the Contributor definition id
```

Resolutions by name (case-insensitive) AND by GUID both land the REAL Azure built-in
role definition GUID into the definition id — no uuid5 fabrication. Close condition
of KD-09 ("smalt Policy face resolves built-in role names to real definition GUIDs")
is met. KD-09 CLOSED.

## KD-05 CORE half check (same session, 2026-11-04)

`grep -rn "GiB\|MiB" lib/smalt --include="*.ex"`: only unrelated caps (event-hub 1 MiB
413, packet-4 16 MiB, MCP 8 MiB, file-share 4 MiB range) — NO quantity-string memory
parsing with unit conversion on the BEAM face. KD-05 CORE half stays OPEN: condition
is the BEAM containerApps face accepting AzureRM-style quantity strings ("1.0Gi")
with unit conversion. POSH-MEMBRANE half CLOSED (see register row).
