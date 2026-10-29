# Receipt — popcorn waves 2–3 consolidated (milestone-doc M-lane)

**Standing:** **PARTIAL_ALIVE** — wave-2/3 capability and defect-closure legs are
ALIVE on the live substrate (real wire, no mocks); the browser blob leg and
the KD-122 flip are loudly OPEN, so the consolidated window is PARTIAL_ALIVE,
not ALIVE.

Context: full (popcorn 8-lane testbed wave landed at `c72e47c`; wave-2/3
lanes ran on the same canonical checkout; consolidate-only lane, no source
edits).

## Sources read (all on disk, verified)

- `docs/jira/v26.10.20/receipts/w21-redact-consolidation.md` — W2-1 redact
  lane, ALIVE (5 redact tests + 7 live tests + 1 suite test, all passed,
  embedded outputs in receipt)
- `docs/jira/v26.10.20/receipts/popcorn-liveblob-lane-l3.md` — L3 blob lane,
  ALIVE (3 consecutive `blob=OK(...:61-roundtrip)` host runs, byte-equal)
- `docs/jira/v26.10.20/receipts/errc-r5-kv-lifecycle.md` — ERRC-R5 KV
  lifecycle, ALIVE (4 tests passed; KD-15 challenge handshake witnessed:
  tokenless 401 + `www-authenticate` → STS token → set/get/delete/404)
- `docs/jira/v26.10.20/receipts/w2f-kd108-acl-lease-wire.md` — w2f ACL/lease
  wire arm, ALIVE (BYTE-COMPARE PASS, lease 201/409/200/202/200, 89 tests
  0 failures internal tier)
- `docs/jira/v26.10.20/receipts/w2i-sb-topics-arm.md` — w2i SB topics ARM,
  PARTIAL_ALIVE (b6 enforce witness exit 0, 15/15 steps PASS; typed AMQP
  fan-out gap open in delivery engine, outside lane files)
- `docs/jira/v26.10.20/receipts/w6R-router-split.md` — router split, ALIVE
  (compile green, `mix test test/internal` → `48 tests, 0 failures`,
  live-wire smoke per delegator arm)
- `docs/jira/v26.10.20/receipts/w3e-kv-purge-bare-delete.md` — on disk,
  cited by lane census; standing per own receipt
- `popcorn_demo/receipts/INDEX.md` — 12 receipts: 4 ALIVE (one marked
  NO-CONTEXT), 1 PARTIAL_ALIVE, 1 SUSPECT, rest NO-CONTEXT-flagged ALIVE
- Newest testbed witness
  `popcorn_demo/receipts/20261021T005640Z-testbed-witness.md` — SUSPECT
  header (browser witness skipped: public/out not cooked), but embeds real
  output: HOST_RECEIPT with 7 legs OK + `param=FAIL(insert_docs:HTTP-400
  ...Partition key...)`; browser SMOKE_RECEIPT carries
  `blob=SKIP(cors-preflight-403:create-container)` — KD-122 still open
- Closure witnesses `20261021T002617Z` + `20261021T003701Z` (ALIVE, solo):
  host legs exit 0 both passes; single persistent browser SKIP
  `blob=SKIP(cors-preflight-403:fetch)`; live-gate shim court PASS
  (`COURT_EXIT:0`, restore sha256 byte-exact)
- Lane partition: `docs/jira/v26.10.20/_LANES.md` (wave A landed, wave B
  IN-FLIGHT at registration)

## KD rows opened this window (verified in the register)

Register: `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md` ("Rows minted this
window (KD-122..)"); canonical table `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.
All three rows read directly from the register file; status OPEN:

- **KD-122** — Blob service CORS on 8443 (stored `<Cors>` rule admits PUT
  202 but not OPTIONS preflight 403; `/healthz` sat before the CORS plug).
  Evidence: coordinator witness 2026-10-20 16:34Z. Close: in-browser
  `blob=OK` in a browser_smoke SMOKE_RECEIPT against a substrate carrying
  the stored rule, flip gated on witness mtime > shim mtime.
- **KD-123** — Queue message PUT with urlencoded content-type stores empty
  MessageText (parser-consumed body class, same as KD-108/KD-122). Evidence:
  ERRC-R4 witness. Close: raw-body exemption with urlencoded-PUT wire
  witness, or typed wire-parity pinion. Receipt-gated.
- **KD-124** — First-ever ARM `PUT .../namespaces/:ns` with sku body answers
  500 after storing the record (retry → 200). Evidence: ERRC-R2 rules-leg
  walk over the real 9443 control plane. Close: consistent 201/200 wire
  witness postdating any shim, or typed ARM-parity error envelope.
  Receipt-gated.

## Defects fixed this window (each with receipt/commit evidence)

- **Parser-consumed-body class (KD-108 remainder)** — `raw_blob_put?/1`
  gained a container-ACL exemption (`comp=acl`); ACL arm reads raw body via
  the BodyCache seam; silent 204 ACL CLEAR became typed 400.
  `receipts/w2f-kd108-acl-lease-wire.md` (ALIVE, BYTE-COMPARE PASS).
- **KD-122 shim landed**: `lib/smalt/egress_router.ex:2134` carries
  `# KD-COVERS: KD-122` (Set Blob Service Properties arm); receipt-gated
  closer `popcorn_demo/scripts/close_kd122.sh` exists and refuses loudly
  (exit 3) until a browser `blob=OK` witness postdates the shim. Flip has
  NOT happened — register row still OPEN.
- **CORS echo knobs** — arm/egress CORS echo `Access-Control-Request-Headers`
  (`headers: ["*"]`, config knobs `:arm_cors_headers`/`:egress_cors_headers`);
  in-browser cosmos preflight 204 witnessed. Evidence: commit `c72e47c`
  message + browser SMOKE_RECEIPT `cosmos_sql=OK` lines.
- **healthz CORS** — `lib/smalt/health_plug.ex` now emits
  `Access-Control-Allow-Origin` (KD-122 part b fix, mounted before
  `:egress_cors`; OPTIONS preflights answered). Register row stays OPEN
  until the full in-browser blob flip lands.
- **JWT redaction** — `popcorn_demo/lib/popcorn_demo/redact.ex`
  (`fragment/1`, JWT pattern → `eyJ<redacted>`, 120-char cap) wired into
  smoke `fail/2` and the application leg catch-all.
  `receipts/w21-redact-consolidation.md` (5+7+1 tests passed).
- **Browser GET-with-body rejection** (wasm slice) + Fetch raw-body JSON
  decode + token leak in FAIL clause + guard `=~` compile error +
  partial-receipt poll race + just toolchain pin — wave-A integration
  defects, itemized in the `c72e47c` commit message.
- **Router fallthrough hardening** — `plug(:w6r_fallthrough)` →
  `safe_subrouter_call/2` under the w6R split; pre-split tree reproduced the
  BEAM "implementation limit" compile blocker; post-fix compile green +
  48/0 internal tier (`receipts/w6R-router-split.md`).
- **File/table plane fence** — file-plane catch-alls were swallowing
  blob-plane GETs for absent shares; fenced with the reserved-prefix law
  (`receipts/w6R-router-split.md` disclosed fixes 2–3; FINAL.md ledger).

## Honest residue (open, receipt-gated)

1. **blob SKIP→OK flip pending witness** — KD-122 flip has not run: newest
   browser SMOKE_RECEIPT still carries
   `blob=SKIP(cors-preflight-403:...)`
   (`popcorn_demo/receipts/20261021T005640Z-testbed-witness.md`). Closer
   `popcorn_demo/scripts/close_kd122.sh` will refuse (exit 3) until a
   fresh browser witness postdates the shim. Do not hand-edit the register.
2. **KD-124 first-PUT-500** — under diagnosis; record persists before the
   crash (retry → 200). No fix receipt yet.
3. **KD-108-class parser traps** — KD-123 (queue urlencoded PUT) open; the
   class (parser consumes body before handler) has now trapped three
   surfaces (KD-108 ACL, KD-122 blob properties, KD-123 queue). Any new
   body-consuming route needs the raw-body exemption review.
4. **w2i AMQP fan-out gap** — topic send lands in the queue-backed topic
   entity; subscription receivers get 0 messages until the delivery engine
   fans out (typed gap in `receipts/w2i-sb-topics-arm.md`, files outside
   that lane's ownership).
5. **param leg FAIL** — latest host witness carries
   `param=FAIL(insert_docs:HTTP-400 ... Partition key provided in the header
   doesn't match ...)` (real substrate state, unowned residue).
6. **Name-check disclosure**: the token "wire_norm" appears NOWHERE on disk
   under `docs/jira/v26.10.20/` or `popcorn_demo/` (grepped). No
   wire_norm court artifact, receipt, or re-anchor record exists in this
   window's tree, so this receipt cannot cite one. If a wire_norm court
   re-anchor is genuinely in flight, it lives outside this window's on-disk
   evidence and needs its own receipt before it can be named here.
7. **Wave-B standing** — the 18-lane closure wave registered IN-FLIGHT in
   `_LANES.md`; lane flips out of IN-FLIGHT are receipt-gated and mostly
   have not landed.

## Falsifiers

- Consolidation is falsified if any named path is absent (every path above
  was `ls`/`grep`-verified on disk at write time) or if any named standing
  disagrees with the cited receipt's own standing line.
- KD-122 close is falsified if `close_kd122.sh` flips while the newest
  SMOKE_RECEIPT contains `blob=SKIP` (the script's own false-flip guard).
- The defect-fix claims are falsified by reverting the named diffs (w2f ACL
  exemption, health_plug CORS origin, redact wiring) and re-running the
  cited suites — each must go red.
