# FINAL — v26.10.29 manufacturing receipt

Window goal: courtroom-platform-az runs against the smalt substrate with no
cloud, no real Entra, no real Redis (see `README.md`).

- subject: smalt @ `35bd36d0` (short `35bd36d0`, full via
  `git rev-parse HEAD`; read-only probe, no state change)
- consumer subject: courtroom-platform-az @ `338caed`
  (`338caed8008727990c03078b348886b8a43d919a`, materialized via
  `git archive` to /tmp — canonical checkout never written)
- date: 2026-10-29
- standing: **PARTIAL_ALIVE** — T01/T02 ALIVE, T03 PARTIAL_ALIVE (leg 3
  BLOCKED on a typed divergence), baseline RED tiers un-triaged

## What landed

| item | receipt | standing |
|---|---|---|
| T01 RESP2 wire listener over `AzureCache.handle/2` | `receipts/r1-t01-redis-wire.md` | ALIVE |
| T01 HELLO pinion flip | `receipts/r1-t01-redis-wire.md` (addendum) | ALIVE |
| T02 SAML 2.0 IdP face | `receipts/r2-t02-saml-idp.md` | ALIVE |
| T03 consumer court harness | `receipts/r3-t03-consumer-court.md` | PARTIAL_ALIVE |
| ash wave + publish-dry disposition | `receipts/r01..r05` | r01/r02/r04/r05 ALIVE, r03 UNKNOWN |

Files per item, cited from each receipt's own "Files landed" section (not
independently re-verified on disk by this lane):

- T01: `lib/smalt/data_plane/redis_wire.ex` (new);
  `lib/smalt/plane/integration_supervisor.ex`;
  `test/integration/redis_wire_test.exs` (new).
- T01 HELLO flip: `lib/smalt/data_plane/azure_cache.ex` (HELLO 3 clause
  only); `test/integration/azure_cache_test.exs` (pin court updated).
- T02: `lib/smalt/identity/saml_idp.ex` (new);
  `lib/smalt/plane/identity_supervisor.ex`; `test/integration/saml_idp_test.exs`
  (new).
- T03: `scripts/courtroom_consumer_court.sh` (new);
  `justfile.d/56-courtroom.just` (new); Justfile import appended.

File lists are cited from each receipt's own "Files landed" section, not
independently re-verified on disk by this lane.

## Verification ladder

1. Baseline r0 (`receipts/r0-baseline.md`, PARTIAL_ALIVE): doctor PASS;
   `just test-offline` 1274/1417 passed, 143 failed; integration
   565/671 passed, 106 failed — RED, failures pre-existing, census-level
   triage only (249-line ledger preserved at /tmp/smalt-validate/).
2. T01 court: `mix test test/integration/redis_wire_test.exs` → exit 0,
   13 passed (real `:gen_tcp` client, byte-exact RESP2 asserts, no sleeps);
   combined with `azure_cache_test.exs` → 28 passed, exit 0.
3. T02 court: `mix test test/integration/saml_idp_test.exs` → exit 0,
   6 passed (real Bandit listener, real xmerl parse, real RSA-SHA256
   recompute, tamper non-vacuity court).
4. T03 legs: leg 1 consumer `npm ci` + `npm run check` rc 0 (node 22.23.4,
   265 packages, 26/26 check tests); leg 2 substrate faces LISTEN
   (redis :16380, saml :19445; real metadata served on GET /metadata); leg 3
   consumer-on-smalt exit 1 — `store: redis` assert FAILED
   (`redis_client_error: ERR protocol error`).
5. r03/r05 publish-dry: r03 UNKNOWN → r05 ALIVE (`just publish-dry` exit 0,
   all four gates PASS).

## RESP3/HELLO pinion flip (typed divergence, closed in smalt)

The pinned `redis@6.3.0` npm client defaults `DEFAULT_RESP = 3`
(`node_modules/@redis/client/dist/lib/RESP/types.js:5`) and sends `HELLO 3`
as its first wire bytes (byte-captured:
`*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n...`); on `-ERR NOPROTO` it retries
forever — no RESP2 fallback. smalt's `azure_cache.ex:193` refused HELLO 3
per the v26.10.28 "RESP2 only" pinion. The coordinator flipped the
`HELLO, ["3"]` clause to answer the success map with `"proto": "2"` (the
wire emits RESP2 only; RESP3-speaking clients parse RESP2 fine) and updated
the pin court to assert the map; combined courts 28/28, exit 0
(`receipts/r1-t01-redis-wire.md` addendum). This SUPERSEDES the
v26.10.28 RESP2-only refusal for the wire-consumer case. The consumer court
has NOT been rerun to green after the flip — leg 3 stays BLOCKED until
`just courtroom-court` exits 0.

## Known toolchain finding (consumer repo, not smalt)

`.nvmrc` pins `20` while `package.json` engines demand `>=22 <25`
(engine-strict via `.npmrc`): a node-20 shell fails `npm ci` outright
(witnessed r0 + r3 leg 1 on machine-default node v20/v26). The court pins
node 22.23.4 explicitly. Reported upstream; not fixed (consumer repo
read-only for this window).

## Open items

1. Baseline RED tiers → dedicated triage lane; `r4-baseline-triage.md` was
   expected but is NOT on disk as of this receipt's write time — in-flight;
   reference when it lands. The /tmp/smalt-validate logs are the ledger.
2. Leg 3 flip to green: rerun `just courtroom-court` after the HELLO flip
   (close condition in `receipts/r3-t03-consumer-court.md`); a parallel lane
   is driving this right now — if `receipts/r3-t03-consumer-court.md` gains
   an ALIVE addendum after this file's write time, that addendum is the
   newer standing and supersedes the PARTIAL recorded here.
3. Honesty-row follow-up in the AzureCache registry: `tcp_port: 0` /
   `wireListener: "none"` rows no longer hold with `:redis_port` configured;
   helpers exposed (`RedisWire.configured_port/0`, `RedisWire.honesty_rows/0`)
   await a coordinator-owned flip (r1 follow-up 1).
4. `:smalt_azure_cache` registry table lazy/heir-created (pre-existing);
   StoreTables regeneration is the integrator's item (r1 follow-up 2).

## Receipt-index check (task 4)

Ran `python3 scripts/receipt_index.py`; it regenerated
`docs/jira/v26.10.29/{RECEIPTS.md,receipts/INDEX.md}` as a side effect
(disclosed: generated artifacts of the index tool itself, deterministically
derived from receipts on disk). Cross-check verdict: "None: every receipt
contains at least one exit-code, test/probe count, or PASS/FAIL token" —
zero SUSPECT receipts in this window. The index reads r3's standing as
UNKNOWN (the parser keyed on the "Standing" heading rather than the
PARTIAL_ALIVE body line); the receipt body is authoritative and says
PARTIAL_ALIVE — noted here rather than fixed (other lane's receipt).

## Standing vocabulary per line

- r0 baseline: PARTIAL_ALIVE (baseline courts RED, pre-existing)
- r01 ash W2a+W4: ALIVE
- r02 W2/W3/W5: ALIVE
- r03 publish-dry disposition: UNKNOWN
- r04 court disposition: ALIVE for the ash wave's own surfaces; court
  ladder BLOCKED on the pre-existing RED tiers (see receipt)
- r05 publish-dry green: ALIVE
- r1 T01: ALIVE (13/13, 28/28, exit 0)
- r2 T02: ALIVE (6/6, exit 0)
- r3 T03: PARTIAL_ALIVE (legs 1-2 rc 0; leg 3 exit 1, typed blocking hop)
- window: PARTIAL_ALIVE
