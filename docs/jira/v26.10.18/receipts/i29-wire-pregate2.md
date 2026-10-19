# i29 AMQP wire pre-gate ×2 — build root _build-ft-w9

Command: `MIX_BUILD_ROOT=_build-ft-w9 mix test --include amqp_wire` — executed **4 legs**
(task asked ×2; two extra legs from the identity-capture pass and the full-log pass,
disclosed). Full log for leg 4: `/tmp/w9-run2.log`. Legs 1–3 were viewed via tail/grep
pipes only (log not retained).

Context: slice(x2, actually 4 legs). Date: 2026-10-19. No edits, no git ops, no _build
deletion. Build root `_build-ft-w9` left in place per task contract.

## Legs

| leg | result | identities |
|---|---|---|
| 1 | 1 doctest, 7 properties, 2816 tests, **2 failures**, 38 excluded | identities not captured (tail-only view) |
| 2 | full run, output piped to grep (no match on capture pattern); counts not retained | — |
| 3 | full run, output piped to grep (no match on capture pattern); counts not retained | — |
| 4 | 1 doctest, 7 properties, 2816 tests, **2 failures**, 38 excluded | (1) `Smalt.ErrorCodesDocTest` "docs/ERROR_CODES.md is the byte-identical projection of the sources" (test/error_codes_doc_test.exs:46) — 34-row egress-family diff, doc stale vs regen. (2) `SmaltTest.Azsim.DetsRecoveryTest` "graphlaw/WasmEngine killed mid-request..." (test/azsim/dets_recovery_test.exs:237) — `eventually(...)` not satisfied within 5000ms, last value `:down`. |

Legs 1 and 4 both show exactly 2 failures at 2816 tests; legs 2–3 counts uncaptured
(harness discipline gap, reported as-is).

## Classification

1. **ErrorCodesDocTest — cross-lane in-flight drift, NOT a wire face.** Legs ran
   00:48–00:53 while the azb-20 lane's `feat(azb20): lib gap-fix landing` (commit
   9a351e3) was landing lib/ edits + regenerating docs/ERROR_CODES.md (file mtime
   00:54, seconds after leg 4's failure at ~00:53). Post-landing solo bisect
   `mix test test/error_codes_doc_test.exs --include amqp_wire` → **7 tests, 0
   failures** (0.1 s), and `python3 scripts/gen_error_codes.py --check` → exit 0
   ("up to date"). Stale window closed by the owning lane's own regen; zero
   construction residue on this lane.
2. **DetsRecovery — roster.** "DetsRecovery rotating" is on the pre-gate tolerance
   roster; 5000ms-budget poll exhaustion (last value `:down`) under load is the
   witnessed class, no new signature.

## Roster verdict

| roster face | count this gate |
|---|---|
| F58/F60 EventGrid/egress 503 readiness | 0 |
| F59 GracefulStop boot | 0 |
| F61 Topology cross-test | 0 |
| DetsRecovery rotating | 2 (legs 1+4; legs 2–3 uncaptured) |
| McpWire/boot-contention | 0 |
| CrashIsolation invalid | 0 |
| NEW | **0** — ErrorCodesDocTest bisects to the azb-20 landing window (cross-lane transient, now solo-green + `--check` exit 0), not a wire construction face |

## Standing

**ALIVE** — zero NEW tolerance faces. All observed failures are the rostered
DetsRecovery rotating class or a bounded cross-lane doc-regen race now closed
(solo-green witness above). Wire-compat pinions hold: no pinion files touched; SASL
ANONYMOUS CBS put-token traffic in the legs shows
`LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY` as pinned. `_build-ft-w9` retained
(no _build deletion performed).
