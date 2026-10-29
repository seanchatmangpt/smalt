# BK-GOPRE — GOSEQ pre-flight progress census

- **Date**: 2026-10-22
- **Standing**: PARTIAL_ALIVE (census lane; all claims from live observation, Context: solo)
- **Context**: solo

## 1. GOSEQ liveness — ALIVE, mid witness-all

`MIX_BUILD_ROOT=_build-bkgoseq just witness-all` is running:

```
sac 68381 ... Python scripts/witness_all.py   (started 8:10AM)
sac 68365 ... just witness-all
sac 68353 ... zsh -c ... MIX_BUILD_ROOT=_build-bkgoseq just witness-all > /tmp/bkgoseq-witness-all.out
```

- `_build-bkgoseq` build root: not yet present in `_build-*` listing (the witness-all
  leg drives `_build-witness`/per-window roots; lane root materializes on first mix leg).
- Output file live: `/tmp/bkgoseq-witness-all.out` (7,398 bytes, growing) — currently
  mid-window on **v26.10.20** receipts:

```
[WITNESS-STALE] docs/jira/v26.10.20/receipts/kd124-namespace-put-close-witness.md no rerunnable command in receipt (standing: PASS)
[WITNESS-STALE] docs/jira/v26.10.20/receipts/kd125-policy-list-close-witness.md no command in a safe class (standing: RUN)
[WITNESS-RUN] docs/jira/v26.10.20/receipts/kd126-ec-create-witness.md class=mix-test cmd=MIX_BUILD_ROOT=_build-w10a mix test test/integration/kv_ec_create_test.exs
```

- GOSEQ receipt: **not landed** (`ls docs/jira/v26.10.22/receipts/ | grep -i goseq` → rc=1).

## 2. BK-WIT4F scope fix — LANDED in working tree (in flight to HEAD)

`scripts/witness_all.py`, mtime Oct 22 08:09:31 (postdates the 08:08 WIT4 receipt):

```python
# Receipt windows: PINNED BY NAME (BK-WIT4-1) — dir mtime is not scope
# authority ...
PINNED_WINDOWS = ("v26.10.20", "v26.10.22")
```

The BK-WIT4-1 mtime-scope drift is fixed; GOSEQ's rerun is using the pinned scope
(confirmed by the live output sweeping v26.10.20 + v26.10.22, no v26.10.14 traffic).

## 3. Substrate state — UP, fresh boot

- `substrate.pid` = **68017**; beam 68017 LISTEN on 9443 + 9545 (lsof embedded above).
- Beam elapsed 00:29 — booted moments before the census (GOSEQ sequence position).
- `/tmp/smalt-substrate-state/smalt-substrate.lock` present but **LOCK-FREE** (flock -n acquires).
- Old checkpoint pid 81426: gone (`ps -p 81426` empty).

## 4. Verdict

**GOSEQ PROGRESSING** — currently in the witness-all rerun step (post WIT4-receipt-wait,
post scope-fix landing, on the freshly booted substrate pid 68017). Remaining per its
sequence: witness-all completion → quiet-check → full suite → gates → receipt.

## Falsifiers

- Not LANDED: no `bkgoseq*` receipt exists (rc=1 grep) — verdict cannot be LANDED.
- Not BLOCKED: live process tree + growing output file observed, no error tail.
