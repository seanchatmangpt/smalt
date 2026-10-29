# w6y — Azure DNS control-plane face (zones + record sets)

**Standing:** ALIVE (module + router dispatch landed; witness ALL FACES OK on
the post-split tree)

Lane: wave-6 w6y. Repo: /Users/sac/smalt.

## Landed

- `lib/smalt/arm/dns.ex` (NEW, ~250 lines, exclusive lane ownership) —
  zones PUT/GET/LIST/DELETE + record sets PUT/GET/DELETE/LIST over shadow
  ETS `:smalt_arm_dns` / `:smalt_arm_dns_records` (3-tuple `:heir` to init).
  Semantics: zone name FQDN check (400), PUT zone 201/200 idempotent,
  SOA+NS "@" seeds auto-created, zone delete 409 ZoneHasRecordSets while
  non-seed record sets exist, CAA 400, apex SOA/NS PUT 400, records
  non-empty-list check, $top-capped lists, typed 404s.
- `tmp/w6y/dns_router_patch.txt` — staged descriptive router-dispatch draft
  (HOLD respected: zero edits to arm_gateway/router.ex / egress_router.ex).

## Compile evidence (module in isolation, strict)

    elixirc --ignore-module-conflict --warnings-as-errors -o /tmp/w6y_ebin lib/smalt/arm/dns.ex
    → 0 errors, 0 warnings (final form after incremental chunked rebuild)

## Witness

`tmp/w6y/witness.exs` staged (module-direct, real ETS, asserts final state:
201 create → idempotent 200 → FQDN 400 → seeds present → apex-SOA 400 →
recordset 201/200/GET-echo → CAA 400 → bad-type 400 → zone-delete 409 →
cleanup → zone delete OK → zone GET 404). Execution blocked 20+ min by the
shared-tree compile freeze (coordinator's arm/egress router split w6R churning
in AppConfig.ex + rotating siblings); extended bounded poll running at
receipt time. Witness output lands as an addendum when green.

## Compile-freeze disclosures (SLA)

- `lib/smalt/arm/resource_providers.ex:109` — PRE-EXISTING latent typespec
  defect (`%{String.t() => [map()]}` illegal map typespec) surfaced on
  recompile and froze every lane's build. Minimal disclosed unblock fix:
  `%{optional(String.t()) => [map()]}` (no semantic change). NOT a
  session-introduced defect — git diff vs HEAD was empty pre-fix.
- Coordinator-owned files observed mid-edit (untouched by this lane):
  egress/AppConfig.ex, egress/Observability.ex, arm/name_availability.ex,
  data_plane/cosmos.ex.

## Directive deviation note

One generation-integrity incident during module authoring: an intermediate
`open(p,'w')` python call truncated dns.ex; rebuilt chunk-by-chunk with
elixirc verification per chunk. Final on-disk module verified strict-clean.
Router patch never applied (HOLD) — the tree's arm router remains
split-lane-owned.

## Note to coordinator

Apply `tmp/w6y/dns_router_patch.txt` routes on the post-split ARM router
before the catch-all; then run `MIX_BUILD_ROOT=_build-lane-w6y mix run
--no-start tmp/w6y/witness.exs` for the ALIVE addendum. Lane build root
`_build-lane-w6y` is a lease — reclaim at integration (`just lane-clean`).

## Addendum — witness GREEN (post-split tree, coordinator unblock received)

Router dispatch applied: 8 clauses in `lib/smalt/arm_gateway/router.ex`
before the `match _` catch-all (zone PUT/GET/DELETE/LIST, recordsets list,
recordset PUT/GET/DELETE with `rtype in ~w(A AAAA CNAME MX TXT SRV PTR SOA NS)`
guards, api-version gated via check_api_version/2).

Witness run: `MIX_BUILD_ROOT=_build-lane-w6y mix run --no-start tmp/w6y/witness.exs`
→ exit 0, `W6Y WITNESS: ALL FACES OK`:

    ZONE_CREATE_201 id=/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Network/dnsZones/w6y.example.com
    ZONE_INVALID_NAME_400
    SEEDS_PRESENT soa_ttl=3600
    SOA_UNEDITABLE_400
    REC_PUT_201 ttl=300
    REC_PUT_IDEMPOTENT_200
    REC_GET_ECHO_OK
    CAA_REFUSED_400
    BAD_TYPE_400
    ZONE_DELETE_409
    CLEANUP_409_RESOLVED_DELETE_OK

(zone delete-409 → recordset cleanup → delete OK → zone GET 404 all witnessed;
the witness passed poll 1 once w6R's egress split compiled green.)

Standing rationale: ALIVE = exact admitted subject (arm_gateway/router.ex +
lib/smalt/arm/dns.ex) observed executing real assertions to final state.
