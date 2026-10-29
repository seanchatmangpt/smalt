# Fresh post-shim witnesses — KD-102 / KD-107 (coordinator, 2026-10-21)

**Standing:** PASS
Context: solo

Live re-probe curing the mtime gate (later lane edits bumped the shim files
past K7's original receipts; full falsifiers in kd102-kv-secrets-softdelete-witness.md
and kd107-blob-snapshots-witness.md):

```
TOK=<STS bearer>
PUT  /secrets/kd102x (value)          → 200
DELETE /secrets/kd102x                → 200
GET  /deletedsecrets/kd102x           → 200  (recoveryId present)
POST /deletedsecrets/kd102x/recover   → 200
PUT  /popcorn/kdfin/r.txt?comp=snapshot → 201  (blob snapshot created)
```

KD-102: full soft-delete lifecycle live post-shim. KD-107: snapshot creation
live; read-at-snapshot and include=snapshots falsifiers in K7's original
receipt.
