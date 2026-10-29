# w6x — Azure Event Hubs Event Hubs Schema Registry emulation

**Standing: ALIVE** — module + delegator routes landed; module-direct faces + real
delegator dispatch witnessed this session, exit 0, real output embedded below.

## Landed

- `lib/smalt/messaging/eh_schema_registry.ex` — schema groups CRUD (PUT
  create-only 201 / 409 GroupExists / GET / DELETE cascade incl. id-keyed rows),
  schema register (byte-identical re-register idempotent; different body → new
  version + new GUID), get-by-id byte-exact echo, versions newest-first, exact
  version read. ETS `:smalt_eh_schemas`, KD-117 heir class
  (`{:heir, Process.whereis(:init), []}`). Full-Avro compatibility resolution is
  a documented boundary (byte-level Forward only).
  (Defects found by the witness and fixed: `%{m | ...}` update on a missing key →
  Map.put; cascade missing id-keyed rows; both now covered by the passing legs.)
  A `^pin` in an :ets match pattern compile error was also caught by the fence.
  (Generation-integrity note: initial large Write corrupted mid-generation — the
  now-thrice-witnessed wave-6 class — recovered via chunked heredoc landings.)
- `lib/smalt/egress/SchemaRegistryRoutes.ex` (NEW delegator, w6R-split shape) —
  registry wire arm: /schemas/ids/:id (byte-exact 200), $schemagroups
  list/PUT/GET/DELETE, POST /schemas/{group}/{name} (201 + Location header),
  versions list + exact read; typed schema_registry_error (400/404/409);
  `match _` fallthrough pass. My original egress_router.ex fragment was LOST in
  w6R's split; re-landed into the delegator structure per coordinator instruction.
- `lib/smalt/egress_router.ex` — w6o's runtime fallthrough mods list carries
  Smalt.Egress.SchemaRegistryRoutes (added by w6o during the split convergence;
  verified present).

## Witness (real output, this session)

- `MIX_BUILD_ROOT=_build-lane-w6x mix run --no-start tmp/w6x_witness.exs` →
  `W6X MODULE FACES: ALL OK` (exit 0):
  group create 201-shape / duplicate 409 GroupExists / register B1 v1 id1 /
  re-register B1 idempotent same id / register B2 → v2 new id / versions [2,1]
  newest-first / get-by-id byte-exact (b1 = b1, byte equality asserted) /
  malformed 400 InvalidSchema / unknown group 404 GroupNotFound / unknown id 404
  SchemaNotFound / DELETE cascade (group + version rows + id rows all gone).
- `MIX_BUILD_ROOT=_build-lane-w6x mix run --no-start tmp/w6x_wire.exs` →
  `W6X WIRE FACE: OK  id=DA70E561-169D-4463-886C-750FAD61179D` (exit 0):
  POST /schemas/w6xw/evt through the REAL Smalt.Egress.SchemaRegistryRoutes
  Plug.Router dispatch → 201 + Location /schemas/w6xw/evt/versions/1; versions
  route → id; GET /schemas/ids/:id → 200 with byte-exact body echo.
- Full-tree `mix compile` GREEN during witness runs (multiple green compiles in
  the bounded polls; the w6R delegator split converged during this lane).

## Compile-freeze SLA disclosures (other lanes' files)

- `cosmos.ex` — restored missing `cosmos_child_of?/2` (3-clause child-key
  helper) called by drop_db/1.
- `AppConfig.ex`/`Kv.ex` — completed the split's dropped restore-route head/body
  (later superseded by the owner's continued edits — owner's converged state is
  what compiles green).
- `SchemaRegistryRoutes.ex`/delegators — `import Smalt.EgressRouter, except:
  [match: 2, dispatch: 2]` disambiguation (my file; the except lists on the
  other five delegators were the owner's converging edits).
- Witness scripts preserved at /Users/sac/.claude/jobs/cfab9d25/tmp/
  w6x_witness.exs + w6x_wire.exs for replay.

## Lane facts

- Build root `_build-lane-w6x` is a lease (coordinator `just lane-clean`).
- No git commands.
