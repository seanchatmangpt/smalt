# EXPL-9 — ERRC read-only sweep: `egress_router.ex` + `arm_gateway/router.ex` (dispatch surfaces)

**Standing:** PARTIAL_ALIVE
Context: solo
Date: 2026-10-22
Lane: EXPL-9 (read-only explore; only this receipt written)

## Scope

The two large dispatch surfaces: `lib/smalt/egress_router.ex` (4333 lines) and
`lib/smalt/arm_gateway/router.ex` (7050 lines). Same defect classes as the
prior EXPL lanes (fail-open guards, untyped MatchError/CaseClauseError on
remote input, silent drops, success-on-unknown-resource, ungated mutating
faces, premise rot). Coverage exclusions applied before minting: KD register
v26.10.22 through KD-173 (KD-155/KD-51 ATOM delete framing, KD-172 SAS
audience, KD-173 ingest HMAC default key — all adjacent, none covering the
findings below), EXPL-6 (covered arm_gateway non-router modules), EXPL-3/5/7
(data plane / BFF). The KD-143 `sb_rule_props` fix in arm_gateway was NOT
regressed by this sweep: PUT resource-group and ATOM alias arms behave
correctly at small body sizes (P2b baseline 201 with parsed
QueueDescription).

## Uncommitted-drift check (lane contract)

- `lib/smalt/messaging/amqp/sas_verifier.ex` — dirty in the session-start
  snapshot; NOT audited here (EXPL-6/KD-172 surface, owned elsewhere).
- `lib/smalt/egress_router.ex`, `lib/smalt/arm_gateway/router.ex` — clean
  relative to HEAD at probe time (probe ran against HEAD + the dirty test
  files listed in the snapshot; none of them touch these two routers).

## Method

Real HTTP against a self-booted ephemeral substrate:
`MIX_BUILD_ROOT=_build-expl9 MIX_ENV=test SMALT_TEST_ARM_PORT=39743
SMALT_TEST_EGRESS_PORT=39744 ... mix run --no-halt -e ":ok"`, then curl
against loopback. Probes P1–P5 below are verbatim curl outcomes; crash
reason read from the substrate log. Substrate torn down after the probes
(port_sweep showed only a foreign enforce-mode beam on default ports,
untouched).

## Findings (ranked, with repair tickets)

### F1 (HIGH, witnessed) — ARM ATOM alias: unguarded `read_body` MatchError → lying 500 on oversized body

`lib/smalt/arm_gateway/router.ex:7013` (`sb_atom_alias/3`):

```elixir
{:ok, body, conn} = Plug.Conn.read_body(conn)
```

`Plug.Conn.read_body/1` (default 8 MB cap) returns `{:more, _, _}` /
`{:error, reason}` for oversized/failed bodies. The match is unguarded, so a
9 MB `application/xml` PUT to `PUT /:entity_name` escapes as a MatchError,
caught by the router's `Plug.ErrorHandler` crash-path fence and rendered as a
**500 InternalServerError ARM envelope** — real Azure answers **413
RequestBodyTooLarge** (Storage/batch arms in egress_router already answer
413 with exactly this contract, see `blob_block_arm`).

Witness (P2): `PUT /q-expl9-bigbody` with 9,437,184-byte `application/xml`
body →

```
HTTP=500
{"error":{"code":"InternalServerError","innererror":{},"message":"Internal server error.","target":"/q-expl9-bigbody"}}

04:57:52.261 error[] arm_gateway crash 500: ** (MatchError) no match of right hand side value: {:more, "xxx...
```

Baseline (P2b): small `QueueDescription` XML → 201 with parsed
`MaxDeliveryCount` — the arm is correct at sane sizes; only the size escape
is defective. Contrast the guarded sibling at `egress_router.ex:2549`
(`blob_block_arm`): `case` with `{:more, partial, _}` → 413
RequestBodyTooLarge envelope — the in-repo canonical shape.

Repair ticket EXPL9-R1: guard the match in `sb_atom_alias/3` (`case` →
`{:more,_,_}` → 413, `{:error,_}` → 400), gate carries `# KD-COVERS: KD-174`
(row to be minted by kd-registrar: "ATOM/ARM alias face answers 500
InternalServerError instead of 413 RequestBodyTooLarge on >8MB bodies";
close condition: 413 witnessed + real azure-servicebus admin client leg
unchanged). Non-vacuity: a 9MB PUT must flip 500→413, baseline P2b unchanged.

### F2 (HIGH, witnessed) — egress `put_range`: same unguarded match AND no crash-path fence at all

`lib/smalt/egress_router.ex:835` (`{:put_range, s, p}` arm):

```elixir
{:ok, body, _conn} = File.read_body... # Plug.Conn.read_body(conn)
```

Same `{:more, _, _}` MatchError class as F1 — but WORSE: the egress router
has **no `Plug.ErrorHandler`** (`grep Plug.ErrorHandler` → no hits; the ARM
router added exactly this fence as GAP-AZB20-3 with the moduledoc noting a
naked adapter-rendered 500 "bypasses every register_before_send callback").
The witness shows the naked form: **empty body, no envelope, no
x-ms-request-id**, adapter-rendered by Bandit.

Witness (P3): `PUT /expl9share/expl9dir/expl9file.txt?comp=range` with 9 MB
`application/octet-stream` body →

```
HTTP=500
(body: EMPTY — no XML error envelope, no x-ms-request-id)
```

Baseline (P5): same path, small body → typed 404 ShareNotFound envelope —
route reachable, crash is specifically the read_body escape. (P4: the
service-properties twin site at line ~1101 is behind an x-ms-version fence —
400 MissingXMsVersion before the body read, so F4-class, not witnessed.)

Repair ticket EXPL9-R2: (a) guard the put_range `read_body` match → 413
RequestBodyTooLarge XML envelope (Storage parity, canonical shape at
`egress_router.ex:2566`); (b) add `use Plug.ErrorHandler` to
EgressRouter rendering the Storage `<Error>` envelope on the crash path
(GAP-AZB20-3 class fence; the arm router's handler is the in-repo template).
Non-vacuity: P3 must flip 500-empty → 413 envelope; a deliberately-raised
crash on another egress route must render the envelope, not a naked 500.

### F3 (MEDIUM, witnessed) — ARM resource-group PUT: empty body succeeds 201 with default location

`lib/smalt/arm_gateway/router.ex:747` `do_rg_put/3`:
`Map.get(payload, "location", "eastus")` — an empty JSON object body (`{}`)
creates a resource group. Witness (P1):

```
curl -X PUT -H 'Content-Type: application/json' -d '{}' \
  'http://127.0.0.1:39743/subscriptions/sub-expl9/resourcegroups/rg-expl9?api-version=2021-04-01'
HTTP=201
{"id":"/subscriptions/sub-expl9/resourceGroups/rg-expl9","location":"eastus",...}
```

Real Azure requires `location` on create: `{}` answers **400** with
`LocationRequired`-class error (az cli: "missing required argument
location"; real ARM envelope code `InvalidParameterTarget...`/`LocationRequired`
— exact code to be pinned by the repair lane against a live capture, not
minted here). The R30 immutable-location guard on update is correct and was
NOT regressed — only the create-without-location fail-open is a divergence.
An SDK client that drops the body field gets a silently wrong record
(defaulted region) instead of a typed refusal — a success-on-missing-field
class defect, softer than F1/F2 because no crash and wire-shape of the
envelope is otherwise right.

Repair ticket EXPL9-R3: on CREATE (not existed?) refuse missing
`location` with a typed ARM 400 envelope; keep update semantics as-is
(location immutable, defaulted value tolerated on update). Non-vacuity: P1
must flip 201 → 400 with location-bearing PUT still 201.

### F4 (LOW, unwitnessed) — egress service-properties arm: same unguarded `read_body` escape, fence-gated

`lib/smalt/egress_router.ex` line ~1101 (`put "/:account"` service-properties
arm):
`{:ok, body, conn} = read_body(conn)` — same `{:more, _, _}` MatchError
class as F1/F2, but behind the x-ms-version fence (P4 answered 400
MissingXMsVersion first), so reaching it requires a valid version header +
9MB body. Same-class repair ride-along with EXPL9-R2 (a): guard → 413.
Non-vacuity: with a valid `x-ms-version` header the 9MB PUT must flip to
413.

### Clean (audited, no finding)

- `maybe_parse_body` / `raw_blob_put?` whitelist (KD-12/R137/KD-108/KD-122
  fences intact, decode+downcase correct).
- CloudEvents/EG1 decode ladder: total decode, typed
  `invalid_cloudevent`/`invalid_eg1_event` 400s, all-or-nothing messaging.
- `with_valid_body`/`safe_dispatch` typed-400 rescue list (R50 repair 3).
- `blob_block_arm` / `blob_batch_arm` guarded read_body `case` arms
  (413/400 contracts) — the canonical shapes F1/F2 should adopt.
- AtomBridge `handle_request` — typed 404/405 on unknown resource/method;
  tolerant regex property extraction with typed defaults (no untyped crash
  face). KD-51/KD-155 comment fences intact.
- ARM `check_api_version`/`send_arm_error` envelopes; R30
  location-immutability guard; deny-by-default `renderable_record?` GET.
- Auth plugs (Bearer/XArrCert/CORS/throttle/request-id) present on both
  surfaces; test-env opt-out is config-scoped, not a code fail-open.

## Receipt footer

Probes P1/P2/P2b/P3/P5 are real curl transcripts against a self-booted
ephemeral substrate (build root `_build-expl9`, torn down after the run;
only this receipt written to the tree). P4 is a real transcript showing the
fence (not the defect site). F4's defect site itself was code-read only —
marked unwitnessed. Build root `_build-expl9` left in place for the repair
lane (EXPL9-R1/R2 can reuse it); per the lane-clean law the coordinator
reclaims it at integration.
