# FIN-16 — Final Doctor Receipt (supplemental + pinned)

Date: 2026-10-15. Lane: DoD-only finish (no commits). Ran last, after F-2
placeholder fix and F-4 `.gitignore` line landed (`.gitignore` mtime ~2 min
before the run).

## Command 1: supplemental DoD doctor

```
just doctor-dod      # exit 0
```

Output (witnessed):

```
doctor_dod (DoD-5) — repo /Users/sac/smalt
WARN  orphan lock holder: /tmp/smalt-substrate.lock exists but no live smalt listeners on ports [9443, 8443], holder pid=52775
WARN  lane build roots: 1 lane build-root lease(s) at repo root, total 340.9 MiB; remediation: `just lane-clean`
INFO  workspace: node_modules present
INFO  workspace: package.json parses (21 deps)
INFO  workspace: @azure/arm-resources pin '^8.0.0' sane (no ^21.x)
INFO  smalt-cli: .venv present (python: /Users/sac/smalt/smalt-cli/.venv/bin/python)
INFO  smalt-cli: py_compile clean over 12 files
INFO  receipts: _LANES.md references no receipts/<lane>.md files (nothing to fail on)
INFO  receipts freshness: 61/61 file(s) inside the 24h session window
INFO  envelope/defect cross-check: all 9 expected gap tokens present
INFO  gap register sync: 2 'CLOSED 2026-10-15' stamps; 9 distinct live GAP(...) tokens in WIRE_PARITY.md (lane-13 census: 5 CLOSED + 9 UNSUPPORTED)

summary: 0 FAIL, 2 WARN (exit 0 unless FAIL fired)
EXIT_DOD=0
```

## Command 2: pinned doctor

```
python3 scripts/doctor.py --json   # exit 0
```

Witnessed tail (per runbook `| tail -3`):

```
    }
  }
}
```

Parsed verdict (from `/tmp/fin16-doctor.json`): `ok: true`, `fixes_applied:
[]`, `advisories: []`, 11/11 checks PASS. Notable INFO-level: 1/15 recent
receipts stale >24h (`smalt-v26.10.14.ocel.json.eds-receipt.json`, 25.3h);
substrate not running (ports free — expected outside a boot).

## WARN classification

- `orphan lock holder /tmp/smalt-substrate.lock (pid 52775)` — **expected
  session residue**: leftover lock from an earlier in-session substrate run;
  no live listeners on 9443/8443. Not introduced by any landed diff.
- `lane build roots: 1 lease, 340.9 MiB` — **expected session residue**: a
  fan-out lane build root awaiting the coordinator cleanup pass
  (`just lane-clean` is the documented remediation).
- Pinned doctor's stale-receipt INFO (25.3h) — **expected session residue**
  (receipts-in-window), not a WARN and not new.

No new WARN, no FAIL, no fixes required.
