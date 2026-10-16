# DoD-5 — fail-closed doctor extension (`doctor-dod`)

Lane: DoD-5 · v26.10.14 · Base: 3fc2543 + working tree · 2026-10-15

## Work order

Extend the Definition-of-Done check surface with a supplemental doctor pass:
6 checks (stale substrate lock, lane build roots, workspace sanity, smalt-cli
sanity, receipts freshness, envelope/defect cross-check). Non-fatal
INFO/WARN; hard FAIL only on the specific DoD conditions. `scripts/doctor.py`
(pinned court) untouched.

## Landed

- `scripts/doctor_dod.py` (NEW, 6 checks as specified)
- `justfile.d/05-doctor-ext.just` — `just doctor-dod` recipe, shebang body,
  `cd` to `justfile_directory()`

## Verification receipt (real output, `just doctor-dod`, 2026-10-15)

```
INFO  substrate lock: lock present AND live listeners 9443 pid=16561 (beam.smp), 8443 pid=16561 (beam.smp) — not stale
INFO  lane build roots: none present (leases cleaned)
INFO  workspace: node_modules present
INFO  workspace: package.json parses (21 deps)
INFO  workspace: @azure/arm-resources pin '^8.0.0' sane (no ^21.x)
INFO  smalt-cli: .venv present (python: /Users/sac/smalt/smalt-cli/.venv/bin/python)
INFO  smalt-cli: py_compile clean over 12 files
INFO  receipts: _LANES.md references no receipts/<lane>.md files (nothing to fail on)
INFO  receipts freshness: 45/45 file(s) inside the 24h session window
FAIL  envelope/defect cross-check: GAP token absent from WIRE_PARITY.md: GAP(blob-comp-lease-absent)
INFO  gap register sync: 2 'CLOSED 2026-10-15' stamps; 8 distinct live GAP(...) tokens in WIRE_PARITY.md (lane-13 census: 5 CLOSED + 9 UNSUPPORTED)
WARN  gap register count drift: 8 distinct live GAP tokens vs census 9
summary: 1 FAIL, 1 WARN (exit 0 unless FAIL fired)
exit code 1 (FAIL fired — correct behavior)
```

## Findings surfaced (real, hand to owning lanes)

1. **FAIL — `GAP(blob-comp-lease-absent)` absent from WIRE_PARITY.md.** The
   token exists only as `UNSUPPORTED(blob-comp-lease-absent)` (line 124);
   lane 13's register grammar is `GAP(name)`. The GAP form exists in
   `docs/compliance/C4_BLOB.md:27,:122`. Register-sync defect for lanes 06/13
   (`docs/WIRE_PARITY.md:124`, grammar drift, not an implementation gap — the
   underlying UNSUPPORTED is documented honestly).
2. **WARN — 8 distinct live GAP tokens vs lane-13 census 9.** Consistent
   with finding 1 (the blob-comp-lease token is not in GAP form, so the live
   GAP census undercounts by exactly 1). Resolves when finding 1 lands.
3. **State change witnessed mid-session**: first run (16:0x) reported 58 lane
   build roots, 33.7 GB... 31.4 GiB total; second run reported none — the
   roots were lane-cleaned concurrently (DoD-6 integration). Doctor reads
   live disk state, verified with `ls -d _build-*` (0 matches after cleanup,
   58 before).

## Check table

| # | Check | Threshold | Witnessed result |
|---|---|---|---|
| 1 | stale substrate lock | WARN if lock without live 8443/9443 listeners | INFO — live beam.smp pid 16561 on both ports; lock not stale |
| 2 | lane build roots | WARN count+bytes, remediation `just lane-clean` | INFO after concurrent cleanup (58 roots / 31.4 GiB witnessed pre-cleanup, WARN machinery proven) |
| 3 | workspace sanity | FAIL: package.json unparseable or `^21.x` arm-resources pin | INFO — parses, pin `^8.0.0`, node_modules present |
| 4 | smalt-cli sanity | FAIL: .venv missing or py_compile errors | INFO — .venv python 3.14.3, py_compile clean over 12 files |
| 5 | receipts freshness | FAIL: receipt referenced in _LANES.md but missing; INFO freshness | INFO — no receipts/ refs in _LANES.md; 45/45 in 24h window |
| 6 | envelope/defect cross-check | FAIL: expected GAP token absent; WARN: count drift vs census | **FAIL: GAP(blob-comp-lease-absent) absent (UNSUPPORTED-form only)**; WARN 8 vs 9 census |

## Standing

ALIVE for the 6 checks on exact subject: working tree @ /Users/sac/smalt,
`just doctor-dod` exit 1 (FAIL fired by design). WARN/FAIL/INFO paths all
witnessed firing. Falsifier for the recipe-exit contract: a run with zero
FAILs must exit 0 — not witnessed this session (a real FAIL fired).

## Notes

- `_LANES.md` contains no `receipts/<lane>.md` references, so check 5's FAIL
  arm has no live subject yet; the parse arm runs on every invocation.
- Session window defined as 24h (mtime-based).
- No commits made, per work order.
