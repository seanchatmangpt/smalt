# Work Order v26.10.15-02 — Receipts as a Queryable Service

**Priority:** P1
**Seeds:** `scripts/receipt_index.py`, `scripts/sdk_coverage.py`, `docs/jira/v26.10.14/{RECEIPTS,KNOWN_DIVERGENCES,SDK_MATRIX}.md`

## 1. Witnessed failures (why this lane exists)

1. **Lanes discover state by grepping.** Every consumer of receipt state today (`doctor_dod.py:236` `check_receipts()`, `justfile.d/10-gap-register-sync.just`, lane docs, human readers) does its own ad-hoc grep/regex pass over `receipts/`, `RECEIPTS.md`, and `KNOWN_DIVERGENCES.md`. Each consumer has its own parser, its own bugs, and its own drift surface.
2. **Index-stale races, repeatedly.** `RECEIPTS.md` and `receipts/INDEX.md` are *regenerated artifacts* (written by `receipt_index.py`, which hardcodes `today = "2026-10-15"` at line 133). Any lane that reads the index rather than the receipts reads a snapshot that can lag by minutes; concurrent `receipt-index` runs rewrite the same files.
3. **Count-restatement drift class.** Doctrine bans restating counts, yet the ecosystem restates constantly: `RECEIPTS.md` headers, `INDEX.md` bullet counts, `SDK_MATRIX.md` ("51 KD rows"), `KNOWN_DIVERGENCES.md` register prose, and `gap-sync`'s hardcoded "35 KD registers all OPEN … 5 CLOSED, 9 UNSUPPORTED" (`justfile.d/10-gap-register-sync.just:47` — **already wrong: the register is at 51 rows**). Every restatement is a future false claim.

## 2. The Move

A small **query CLI** — `scripts/receipts.py` (new; reuses scan functions imported from `receipt_index.py`). **Design invariant: no second store.** The CLI is a *projection* over the receipts directory and KD table, read at invocation time. It never writes state, never caches across invocations — no new drift surface. Generated artifacts (`RECEIPTS.md`, `INDEX.md`, `SDK_MATRIX.md`) remain regenerable recipes; the query layer never reads them as source of truth (it reads the raw receipt files and `KNOWN_DIVERGENCES.md` directly).

## 3. Spec — subcommand surface

All subcommands emit **one JSON object per line** (JSONL) by default; `--table` for human rendering. All commands accept `--release <ver>` (default `v26.10.14`; no per-release hardcode — unlike `receipt_index.py`'s hardcoded `JIRA` path).

### `receipts.py standing <lane-id> [--require TOK[,TOK...]]`
- `<lane-id>`: exact lane id, unique filename prefix, or unique substring across `receipts/` + `sdk-results/`. Ambiguous → exit 3 with candidates on stderr.
- JSONL: `{"lane":"06","file":"06-blob.md","standing":"CLOSED","verdict_line":"...","suspect":false,"path":"..."}`
- `--require CLOSED` → exit **0** iff standing matches AND not SUSPECT; **1** present-but-mismatched/SUSPECT; **2** no file. This is the gate primitive.

### `receipts.py divergences [--surface S] [--open] [--status STATUS]`
- Parses the KD table in `KNOWN_DIVERGENCES.md` (pipe-delimited rows).
- JSONL: `{"id":"KD-01","surface":"...","evidence":["sdk-results/py-storage-blob.md"],"status":"OPEN"}`
- Exit 0 always (a query, not a gate); exit 2 if the KD table is unparseable.

### `receipts.py coverage`
- Wrapper over `sdk_coverage.py`'s inventory + KD cross-check: one JSONL row per surface `{"surface":"cosmos","ts":"REGISTERED-DIVERGENCE","py":"PASS","kd":["KD-36","KD-44"]}`.
- Does NOT regenerate `SDK_MATRIX.md`; consumes `sdk_coverage.py` as a library (refactor main into `build_matrix() -> list[dict]`; the .md writer renders those rows).

### `receipts.py gaps`
- `{"class":"MISSING","ref":"receipts/05-arm-lro.md","where":"_LANES.md"}` — referenced but no file.
- `{"class":"SUSPECT","file":"...","standing":"...","reason":"no exit-code/test-count/PASS-FAIL token"}` — reuses `receipt_index.has_evidence`.
- `--strict` additionally flags `standing == "UNKNOWN"` as `{"class":"UNTYPED", ...}`.
- Exit 0 clean, 1 if any gap. This is the falsifier target.

## 4. How lanes consume it

- Gate: `python3 scripts/receipts.py standing 06-blob --require CLOSED || exit 1`.
- Index-stale race eliminated structurally: lanes query files directly; `receipt_index.py` stays the .md writer only (remove the date hardcode; note the race caveat in its docstring).
- `doctor-dod` integration: `check_receipts()` delegates to receipts.py functions.
- `gap-sync` integration: drops its hardcoded "35 KD" claim; consumes `divergences --open` + `WIRE_PARITY.md` census tokens; additionally runs `gaps --strict` and fails on any row.
- `RECEIPTS.md` stays a recipe; nothing gates on the .md — the gate reads files.

## 5. Falsifier

```bash
echo '# fake receipt
Status: CLOSED
' > docs/jira/v26.10.14/receipts/zz-fake.md
python3 scripts/receipts.py gaps   # expect exit 1, row class=SUSPECT file=zz-fake.md
rm docs/jira/v26.10.14/receipts/zz-fake.md

mv docs/jira/v26.10.14/receipts/06-blob.md{,.bak}
python3 scripts/receipts.py standing 06 --require CLOSED   # expect exit 2, {"error":"no receipt file","lane":"06"}
mv docs/jira/v26.10.14/receipts/06-blob.md{.bak,}
```

## 6. Acceptance commands

```bash
python3 scripts/receipts.py standing 06 --require CLOSED; echo $?          # 0
python3 scripts/receipts.py standing nonexistent-lane; echo $?             # 2
python3 scripts/receipts.py divergences --open | wc -l                     # = open KD count (51 today)
python3 scripts/receipts.py coverage | wc -l                               # = len(SURFACES) in sdk_coverage.py
python3 scripts/receipts.py gaps; echo $?                                  # 0 on clean tree
just receipt-index-check                                                    # still clean after refactor
just doctor-dod                                                             # receipts section still passes
just gap-sync                                                               # passes, no hardcoded counts left
```

## 7. Files owned

- `scripts/receipts.py` (new)
- `scripts/receipt_index.py` (extract shared functions; remove date hardcode; stays .md generator)
- `scripts/sdk_coverage.py` (refactor main → `build_matrix()`)
- `justfile.d/10-gap-register-sync.just` (consume CLI, drop hardcoded counts)
- `scripts/doctor_dod.py` (`check_receipts()` delegates)
- `docs/jira/v26.10.15/02-receipts-query-service.md` (this doc)

**Not owned:** receipt files, KD statuses, RECEIPTS/INDEX/SDK_MATRIX content (regenerable), `justfile.d/13-receipt-index.just`.
