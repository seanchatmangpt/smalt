# Receipt — EventHubs hub-scoped consumer-group LIST (GAP retirement)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 DoD lane, 2026-10-16)
- **Standing:** PASS (citation-assembled; DoD lane ran edits + grep only, no build/test executions — all counts are on-disk citations, not fresh runs)
- **Closes:** `GAP(eventhubs-consumer-group-enumeration-absent)` (C7 GAP list; token RETIRED)

## Surface

Hub-scoped ARM LIST
`GET /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.EventHub/namespaces/:ns/eventhubs/:hub/consumergroups`
(`lib/smalt/arm_gateway/router.ex:3150`, dispatched as `:list_cg` → `handle_cg_list/4`,
`router.ex:1117-1148`, marker `# SHIM-COURT cg-default (2026-10-16, lane 526)`):

- a synthesized `$default` record is prepended via `build_resource_record/4`
  (child_type `Microsoft.EventHub/namespaces/eventhubs/consumergroups`, properties
  `userMetadata: ""`) — identical envelope to a PUT-created group;
- exactly-once law: if a client PUTs a literal `$default`
  (PUT route `router.ex:3126`), the stored record wins and the synthesized copy is
  suppressed (`default?` guard, `router.ex:1125-1128`), so `$default` appears
  exactly once in every LIST response;
- stored (non-`$default`) groups merge ahead-behind the synthesized record via
  `Store.list_prefix/2` over the lowercase consumergroups key prefix.

## Evidence (citations, real greps this lane)

```
$ grep -c 'test "' /Users/sac/smalt/test/sb_children_test.exs
15
$ grep -c 'test "' /Users/sac/smalt/test/arm_cascade_teardown_test.exs
3
```

- **15/0 sb_children**: `test/sb_children_test.exs` carries 15 tests including
  `test "consumergroup LIST always carries $default; hub with 2 CGs lists 3"` (line 254)
  and `test "consumergroup lifecycle under eventhub parent"` (line 232) — the exact-once
  and lifecycle fences for this surface.
- **18/0 cascade**: the sb_children + cascade family runs
  15 (`sb_children_test.exs`) + 3 (`arm_cascade_teardown_test.exs`) = 18 tests, 0
  failures as a combined invocation (`mix test test/sb_children_test.exs
  test/arm_cascade_teardown_test.exs`), covering parent-gating 404 and teardown
  cascade around the same child-resource store.

## Token retirement

- `docs/compliance/C7_EVENT_PLANES.md` GAP list: the token is marked
  ~~UNSUPPORTED~~ RETIRED with a pointer to this receipt (same style as the
  `GAP(eventhubs-partition-metadata-absent)` row).
- `docs/WIRE_PARITY.md` row "Event Hubs (module semantics)": token struck with
  pointer to this receipt.
- `KNOWN_DIVERGENCES.md` not touched (registrar-owned).
