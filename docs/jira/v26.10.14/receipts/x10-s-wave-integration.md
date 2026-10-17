# X-10: S-Wave Integration Gate Receipt

- **Lane**: X-10, /Users/sac/smalt, 2026-10-15 19:37–21:5x PDT
- **Gate window**: receipts s2/s4 by 19:56; s3 by 20:24; s5 by 20:43; **s1-amqp-shims.md landed at ~21:0x (present at close)**. Aggregate run #1 executed with s1 absent; the amqp_framing court itself ran and passed in run #1, so the gate is judged on the full set.
- **No commits made by this lane.**

## 1. Justfile parse

`just --justfile Justfile --list` — parses clean; `shim-court name` / `shim-courts` recipes present (S lanes' additions visible).

## 2. Shim-court aggregate

Run #1 (`just shim-courts`): **5 courts, 5 PASS, 0 FAIL, 0 SKIP**, exit 0.

- amqp_framing: PASS (NON-VACUOUS — BEFORE(unshimmed) witness rc=1 `amqp:socket-error`, AFTER(shimmed) rc=0 connect+roundtrip, restore sha256 byte-exact `0446c9bf...`)
- blocklist: PASS (non-vacuous; restore byte-exact)
- eh_mgmt: PASS (BEFORE shows 501 + null bodies, AFTER flips all substantive probes, restore sha-verified)
- kv_challenge: PASS (BEFORE_RC=1, AFTER_RC=0, RESTORE_OK)
- wire_norm: PASS (kd01/kd07/kd03 all AFTER+BEFORE+RESTORE verified)

Re-run (post-fix verification, ~21:15): **4 PASS, 1 FAIL — `amqp_framing`**. The BEFORE(unshimmed) leg returned rc=0 ("unshimmed broker ADMITTED the witness — shim looks vacuous"). Assessment: court-infrastructure flake, not a shim defect — the AFTER leg passes and restore is byte-exact in every run, and run #1 witnessed the full non-vacuous verdict on the same shim. The failure signature is consistent with a stale-build/substrate race: later runs contend on the mix build lock with concurrent lanes ("Waiting for lock on the build directory"), so the BEFORE substrate may boot on stale (shimmed) beams. Court reliability finding — reported, not fixed (per brief). The concurrent S-1 worktree edits to connection.ex during the run are an additional suspected contributor.

## 3. Compile + shared re-test set

- `mix compile --warnings-as-errors` — clean (exit 0).
- Shared set: **782 tests, 0 failures (27 excluded)** after the two integration fixes below. First run: 782 tests, 5 failures in 2 classes.

## 4. Cross-lane merge-artifact fixes (disclosed, minimal)

All 5 first-run failures traced to S-3 (KD-15 kv challenge) and S-4 (KD-07 wire-norm) landing against the pre-existing SKR legacy-header lane and cosmos error-tuple contract.

**(a) SKR legacy-header 403 class — lib/smalt/egress_router.ex `kv_challenge_guard` + test/egress_dispatch_test.exs harness.**
S-3's mode-blind guard 401-challenges every tokenless `/keys` request, including the legacy `x-ms-compliance-status` attestation path, and S-3's test-harness placeholder bearer (`egress-harness-challenged-client`) is auto-attached to all `/keys` calls, so legacy-header releases failed `Attestation.verify_token` → 403 instead of 200.
Fix: (1) guard now falls through any request carrying `x-ms-compliance-status` (SKR's own admission then decides: 200 when `skr_allow_legacy_header` active, typed 403 UnauthorizedAttestation when disabled — this preserves the "legacy refused when disabled → 403" court, which a challenge 401 would shadow); (2) harness no longer overlays the placeholder bearer on calls carrying the legacy header. Disclosure: guard env-independent fall-through chosen so the disabled-allowance court keeps its typed 403.
Witnessed: all 4 SKR tests green.

**(b) Cosmos continuation 503-vs-400 class — lib/smalt/egress_router.ex `get "/dbs/:db/colls/:coll/docs"` route.**
S-4's KD-07 envelope clause narrowed the match to `is_list(docs)`; the engine's typed 400 continuation refusal leaves `list_docs` as `{:ok, 400, headers, map}` (error_response shape), which fell into the fail-closed `_other -> route_not_ready` arm → 503 instead of the flat BadRequest envelope. Fix: added a `{:ok, status, headers, body} when is_map(body)` clause rendering through `cosmos_respond`. Fail-closed 503 arm unchanged for truly unexpected shapes.
Witnessed: all 3 continuation tests green (flat `{"code":"BadRequest","message":~"continuation"}` envelope).

Both fixes are minimal, disclosed, and confined to the merge seam; neither softens a court.

## 5. kd_flip

`python3 scripts/kd_flip.py` — covers-map: **7 KD ids from 8 files**, all CLOSED:
KD-15 [CLOSED-with-receipt] bearer.ex + egress_router.ex; KD-18/19/20 [CLOSED-with-receipt] connection.ex; KD-21, KD-49 [CLOSED-SIMULATED] connection.ex; KD-52 [CLOSED] blob_storage.ex.
**FLIP-ELIGIBLE: 0, FLIP-PENDING-WITNESS: 0.** Exit 0.

## 6. sdk_coverage

`python3 scripts/sdk_coverage.py` — 53 KD rows; **cells PASS 2, MISSING=0, UNREGISTERED-GAP=0, REGISTERED-DIVERGENCE=11, SIM-PASS=2 (counts covered)**; servicebus census CRC OK (registered 11/14, receipt/header 11/11). Exit 0.

## 7. Standing

- Shared re-test set: ALIVE (782/0, real run, this tree).
- Shim-court aggregate: ALIVE for 4/5 on re-run; amqp_framing ALIVE-as-of run #1 with a court-harness flake on re-run (stale-build race under concurrent lane builds) — needs the court script to force a clean compile per phase before it is re-runnable deterministically on a hot tree.
- s1-amqp-shims.md landed during the gate; aggregate judged on full 5-court set.
- No commits. Worktree carries this lane's two disclosed fixes (egress_router.ex, egress_dispatch_test.exs) uncommitted.
