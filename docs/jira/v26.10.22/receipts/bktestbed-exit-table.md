# BK-TESTBED — TESTBED.md canonical exit table refresh (BK-POPCORN flag)

**Standing:** **ALIVE** (OK path executed on the live substrate; SKIP path source-verified
in the gate + witnessed in `bk-popcorn-live.md`; all other documented exit rows
re-verified against gate source)

Context: solo

## Scope

BK-POPCORN's live-leg fix changed `scripts/browser_smoke.mjs` exit semantics
(exit now keyed on the `live=` fragment, not on any `=FAIL` anywhere). This
lane re-verified every exit contract documented in `docs/TESTBED.md` against
gate source and updated the rows that drifted. Only `docs/TESTBED.md` + this
receipt touched.

## Row-by-row verification

| TESTBED row | Verification | Verdict |
|---|---|---|
| Exit-code contract bullet (§Chicago discipline) | Read `popcorn_demo/scripts/browser_smoke.mjs` (lines 96–162): exit keyed on `live=` fragment; `live=OK`→0 (other `=FAIL` still forces 1); `live=SKIP`→3 / 0 with `SMOKE_ALLOW_OFFLINE=1`; `live=FAIL`/missing→1; `finalExit = exitCode === 3 ? 3 : Math.max(exitCode, scvdGate.verdict)` — a 3 is never upgraded. | **DRIFTED → updated** (doc said "1 = any FAIL(...)" — under the new gate a `=FAIL` does not force 1 when `live` itself skipped) |
| Charter table control-plane row gate cell | Updated to name the `live=`-keyed contract. | updated |
| SCVD T16 fragment gate (post-exit computation) | Source lines 115–159: absent/malformed/degraded/t16 > 3x rolling-best all verdict 1; exit-3 preserved. Witnessed live: `SCVD_GATE: SCVD-OK:t16:5.699ms <= 3x rolling-best 5.214ms`. | verified, no drift |
| close_kd.sh exit paths (§KD status matrix / closer law) | Source: already-CLOSED → `REFUSED(...) exit 1`; no canonical row → exit 1; no `KD-COVERS` shim → `NOT-ELIGIBLE(...) exit 3`. Matches doc ("no shim -> exit 3", "loud REFUSED exit 1"). | verified, no drift |
| emulators.sh `EMULATORS-DOCKER-ABSENT` exit 3 (§Named exceptions table W30-N) | Source line 36/160: `typed_absent() { ... exit 3 }`. | verified, no drift |
| loud-skip contract, ACR row | Witnessed in this run: `acr=SKIP(face-absent::acr_face_absent)` in the composed receipt. | verified, no drift |
| wasm-transport SKIP law / eh-plane-down / ca-missing skip labels | Witnessed in this run: `apim=SKIP(wasm-transport:...)`, `topic=SKIP(wasm-transport:...)`, `eg=SKIP(wasm-transport:publish)`, `eh=SKIP(eh-plane-down(5673-...))`, `tls=SKIP(ca-missing:...)`. | verified, no drift |
| Gate poll discipline (waits for composed `live=` line) | Source lines 86–89: loop breaks only on `receipt.includes("live=")`. | verified, no drift |
| Terminal witness `popcorn_demo/scripts/witness_all.sh` | `ls` verified on disk. | verified, no drift |

## Embedded verification output (OK path, substrate UP, 2026-10-22)

```
$ cd popcorn_demo && node scripts/browser_smoke.mjs; echo "EXIT=$?"
SEED_BLOB_CORS: OK — popcorn <Cors> rules seeded (202, PUT .../popcorn?restype=service&comp=properties)
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:60605
[console] [Popcorn] stdout: popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)
SMOKE_RECEIPT: cosmos_sql=OK(...); acr=SKIP(face-absent::acr_face_absent);
  apim=SKIP(wasm-transport:...); appconfig=OK(popcorn-ac-1082:kv+flag-lifecycle);
  blob=OK(popcorn/.../receipt.txt:61-roundtrip); cas=OK(...); ...;
  eh=SKIP(eh-plane-down(5673-connect-:eprotonosupport); run 9>&- just substrate-up);
  live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:6-matched);
  scvd=OK(t16:5.699ms,...); tls=SKIP(ca-missing:...); topic=SKIP(wasm-transport:...)
SCVD_GATE: SCVD-OK:t16:5.699ms <= 3x rolling-best 5.214ms
EXIT=0
```

(29 legs rendered, `BROWSER_LEG_ROW {"lane":"browser-legs","legs_rendered":29,...}`.)

SKIP path not re-executed: substrate is shared and UP (other lanes riding it);
bouncing it is outside this lane's ownership. The exit-3 / ALLOW_OFFLINE-0
SKIP contract is source-verified in the gate and witnessed on the recooked
bundle in `docs/jira/v26.10.22/receipts/bk-popcorn-live.md` (exit 3 down;
exit 0 with `SMOKE_ALLOW_OFFLINE=1`).

Also verified non-drift: the e2e/sdk `0/1/2/3` exit contract lives in the repo
`CLAUDE.md` test-ladder section, not in `docs/TESTBED.md` — no TESTBED row
carries it, nothing to update here.

## Typed finding (disclosure (c), owner flagged, not fixed)

**Finding BK-TESTBED-F1 — narrower skip classifiers on appconfig/rg legs.**
`popcorn_demo/lib/popcorn_demo/live_appconfig.ex` and `live_rg.ex` classify a
downed substrate as `appconfig=FAIL(fetch)` / `rg=FAIL(fetch)` (witnessed in
`bk-popcorn-live.md`) instead of `SKIP(substrate-down:<r>)`. This contradicts
the TESTBED fragment law (§Purpose: "skips are loud"; §Chicago discipline /
M1 label law: a substrate-not-up condition is observed via connect failure
and emitted as `SKIP(...)`, never a FAIL — the live leg itself now uses the
`econnrefused|failed to fetch` classifier). Under the current gate this is
masked when `live=SKIP` (exit keyed on live, FAILs ride loudly) but would
force a spurious exit 1 if those legs FAIL while `live=OK` on a flapping
substrate. **Owner: the appconfig/rg leg owners** (same surface class as
BK-POPCORN's live-leg fix #1). Not fixed by this lane — outside file
ownership.

**CLOSED 2026-10-22 (lane BK-SKIPFIX)** — both legs now use the same
`econnrefused|failed to fetch` classifier and emit
`appconfig=SKIP(substrate-down:<step>:<r>)` / `rg=SKIP(substrate-down:...)`;
witnessed both ways in
`docs/jira/v26.10.22/receipts/bkskipfix-classifiers.md`.

## Diff summary

- `docs/TESTBED.md`: exit-code contract bullet rewritten to the live=-keyed
  contract (0 / 1 / 3 / ALLOW_OFFLINE downgrade / exit-3 preservation);
  charter table control-plane row gate cell names the keyed contract.

## Falsifier status

- A run, substrate UP, where the gate exits nonzero on `live=OK` + SCVD-OK:
  REFUTED (observed exit 0).
- A doc row still claiming "1 = any FAIL(...)": REFUTED (gate source
  contradicts; TESTBED.md updated).
- close_kd.sh / emulators.sh exit rows drifting: REFUTED for now (source
  matches doc); re-checked on this tree 2026-10-22.
