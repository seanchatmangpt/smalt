# HAVE-6 — RP-02 deterministic storage recovery probe

Standing: **ALIVE** (all four modes executed on real dets subjects, exit codes witnessed)

Component 6 of the HAVE plan: `scripts/have/storage_probe.py`, the RP-02
read-only storage probe. Never repairs (`repair: false` is the only open
mode); recovery belongs to `DetsMirror.restore`
(`lib/smalt/store/dets_mirror.ex`).

## Subject

- `/Users/sac/smalt/scripts/have/storage_probe.py` (new)

## What landed

- `--inspect-headers --data-dir DIR`: per-table header check (DETS magic
  `00 ab cd ef` at offset 4, zero-length reject).
- `--verify-clean-open --data-dir DIR`: strict fail-closed open of every
  `.dets` with `repair: false` via a real `dets` collaborator (escript),
  reusing the i24/i25 probe_rows tuple-shape matcher:
  `{:ok,_}` -> OK, `{:needs_repair,_}` -> NEEDS_REPAIR,
  `{not_a_dets_file,_}` -> CORRUPT_HEADER, other -> OPEN_ERROR.
- `--quarantine`: on any corrupt verdict, tars the data dir to
  `tmp/have/quarantine/corrupt_state_<ts>.tar.gz` and exits 1.
- `--ledger-pointer`: names the replay source —
  `smalt-cli/audit_manifest.jsonl` (rolling SHA-256 chain) with fallback
  to `docs/jira/v26.10.18/receipts/`.

## Witnessed runs (real output)

Fixtures: `tmp/have/fixture/{clean,corrupt,torn}/dm_t_resources.dets`
(clean file created by a real `dets:open_file/insert/sync/close` cycle;
corrupt = first 19 bytes overwritten with GARBAGE; torn = truncated to
3000 bytes).

Clean fixture:

```
== verify clean open (repair: false): tmp/have/fixture/clean
  dm_t_resources.dets      OK
clean exit=0
```

Corrupt fixture (header magic destroyed):

```
== header inspection: tmp/have/fixture/corrupt
  dm_t_resources.dets      CORRUPT_HEADER  (magic 4147452d)
== verify clean open (repair: false): tmp/have/fixture/corrupt
  dm_t_resources.dets      CORRUPT_HEADER
== quarantined corrupt state: /Users/sac/smalt/tmp/have/quarantine/corrupt_state_20261019T043223.tar.gz
corrupt exit=1
```

Torn fixture (truncated mid-write):

```
  dm_t_resources.dets      NEEDS_REPAIR
torn exit=1
```

Ledger pointer (real manifest, real last entry hash):

```
RP-02 replay-from-ledger pointer:
  verified hash-chained ledger: /Users/sac/smalt/smalt-cli/audit_manifest.jsonl
  latest entry_hash: 500cd11e71fb74853489e0316a022f007e3ff95720c68ede0ef5a071f617035b
exit=0
```

## Falsifiers

- Corrupt fixture detected CORRUPT_HEADER and produced a quarantine tar: **confirmed**
- Clean fixture exits 0 with OK: **confirmed**
- Torn fixture returns the typed NEEDS_REPAIR shape: **confirmed**

## Not done here

- No repair path (by design; DetsMirror.restore owns recovery).
- No git commit (per task constraint).
