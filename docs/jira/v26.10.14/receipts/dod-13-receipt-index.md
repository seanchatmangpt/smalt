# Receipt — DoD-13 manufacturing-receipt index

- Date: 2026-10-15
- Lane: DoD-13 (receipt-index)
- Subject: `/Users/sac/smalt` working tree @ HEAD `3fc2543` (uncommitted, shared checkout)
- Owned artifacts: `scripts/receipt_index.py` (new), `justfile.d/13-receipt-index.just`
  (recipe `receipt-index`), `docs/jira/v26.10.14/RECEIPTS.md` (generated),
  `docs/jira/v26.10.14/receipts/INDEX.md` (generated, short).

## Delivered

- Enumerated every receipt file on disk at final run: 48 files in
  `docs/jira/v26.10.14/receipts/` + 10 in `docs/jira/v26.10.14/sdk-results/`
  = 58 receipt files (count as-of 2026-10-15 final run; lanes were still
  landing receipts mid-index — 43 at first scan, 48 at final rerun; the
  generator is arrival-robust: rerun picks up new files).
- Moved two smalt-cli receipts that landed in the wrong place
  (`smalt-cli/docs/jira/v26.10.14/receipts/cli-03-gateway.md`,
  `cli-06-hw.md`) to the canonical `docs/jira/v26.10.14/receipts/` via plain
  `mv`; removed the now-empty `smalt-cli/docs/jira/v26.10.14/receipts` tree.
- `scripts/receipt_index.py`: scans both dirs, extracts each receipt's own
  verdict line (status/standing/verdict/result), canonicalizes to a standing
  token (ALIVE / PARTIAL_ALIVE / DONE / COMPLETE / LANDED / CLOSED / PASS /
  FAIL / SKIP-LOUD / UNSUPPORTED / UNKNOWN), extracts a one-line summary from
  the first heading, and checks for real command output (exit code, test/probe
  count, PASS/FAIL token). No-output receipts are flagged **SUSPECT**.
- Generated `RECEIPTS.md` with sections: Release work orders
  (V261014-01..20 + 05/06 sub-receipts), Workspace (ws-01..12), smalt-cli
  (cli-01..08), SDK validation (ts-*/py-*), Enclave testbed, DoD lanes
  (dod-01..13), Cross-check / SUSPECT flags.

## Gates / commands (real output)

- `python3 scripts/receipt_index.py` →
  `receipts=48 sdk=10 total=58 suspects=1`, exit 0 (final run).
- Spot-check (grep for exit/test-count evidence) — all three contain real output:
  - `receipts/07-cosmos.md`: `mix test test/data_plane/cosmos_test.exs` → **105 tests, 0 failures**; **133 tests, 0 failures**; restart court × 10 → `10 × 1 test, 0 failures`.
  - `receipts/ws-12-e2e.md`: `# PASS=33 FAIL=6 SKIP=2  (exit 1)`; six targeted checks PASS, court verdict FAIL disclosed with exit code.
  - `sdk-results/ts-arm-resources.md`: `## Verdict: 8/11 probes passed` + per-probe PASS rows with raw HTTP evidence.
- Mid-run arrival handled: `receipts/dod-08-publish-dry.md` landed during
  indexing; generator classifies it under DoD lanes (its own content shows
  `publish-dry → exit 0` + `PASS (tarball: 301056 bytes)` — real output,
  not SUSPECT).

## Standing / flags

- Standing: **ALIVE** — generator runs, exits 0, writes both files; index
  tables witnessed on disk (43 + 10 + enclave + DoD rows).
- SUSPECT flags: 1 — `receipts/06-blob-x-ms-date-unvalidated.md` (standing
  UNSUPPORTED). It is a typed UNSUPPORTED *disclosure* (documents the
  unvalidated `x-ms-date` divergence with no probe output in-file); flagged
  conservatively by the no-output rule.
- Gaps disclosed: enclave testbed has no receipt file (log only,
  `tmp/enclave-testbed.log`, mixed PASS/FAIL — standing PARTIAL);
  dod-01..07 and dod-09..12 have no receipt files (justfile modules only;
  `dod-08-publish-dry.md` is the one DoD receipt besides this one);
  `smalt-cli/docs/jira/v26.10.14/receipts/cli-02-ledger.md` remains in the
  non-canonical location — not in this lane's named-move list, left for the
  cli-02 owner; several receipts carry standing UNKNOWN (no parseable verdict
  line) — the index shows their extracted summary instead.
- Replay: `just receipt-index` (or `python3 scripts/receipt_index.py`); run
  twice → identical output (idempotent regeneration).

## Falsifier

- Deleting any receipt file and re-running the recipe changes the counts and
  the table row disappears; if regeneration does not reflect the directory,
  this receipt is dead.
