# AU-10 Audit Ledger (smalt-cli)

NIST AU-10 (assurance of audit information) append-only manifest for
smalt-cli. Stdlib only. Implementation: `smalt_cli/ledger.py`; tests:
`smalt_cli/test_ledger.py`.

## Manifest

`audit_manifest.jsonl` — one JSON object per line:

```json
{"actor":"tester","hash":"<64 hex>","op":"blob.list","params_digest":"<64 hex>","prev_hash":"GENESIS","ts":"2026-10-15T00:00:00Z"}
```

- `params_digest` = sha256 of canonical JSON of the op params.
- `prev_hash` = `GENESIS` for the first record, else the previous record's
  `hash`.
- `hash` = sha256(`prev_hash` + canonical(record-without-hash)) — rolling
  block-hash chain.

Canonical JSON = `sort_keys=True, separators=(",", ":")`, UTF-8. Same record
sequence always produces a byte-identical file (NFR-PY-05).

## API

```python
from smalt_cli import ledger

ledger.append_record(path, op, actor, params, ts)  # -> record dict; flush + fsync
ledger.verify_manifest(path)  # -> {"intact": bool, "count": int,
                              #     "first_break": int | None, "reason": str | None}
```

`verify_manifest` is total: a malformed line is a typed failure
(`reason` starting with `malformed_json`, plus the raw `line`), never an
exception. `first_break` is the 0-based line index of the first violation.
Failure reasons: `missing_manifest`, `malformed_json`, `record_not_object`,
`missing_field`, `chain_break`, `hash_mismatch`.

## Tests

```sh
python3 -m pytest smalt_cli/test_ledger.py -v
```

Covers: append+verify green, one-byte tamper detected at the exact line,
empty-manifest GENESIS handling, missing file, malformed JSON, chain break,
byte-identical determinism across two runs, order-insensitive params digest.
