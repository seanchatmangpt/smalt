# Receipt: X-4 naming-sweep scope fix (2026-10-15)

**Lane**: X-4 (F-14 finding). **No commits** (per dispatch).

## Subject
`scripts/naming_sweep.sh`, `scripts/publish_dry.sh` (exclusion only), 17 violation
sites, receipt `x4-naming-scope.md`.

## Finding
The landing commit (518b31a) tracked ~163 hits of lane prose under
`docs/jira/v26.10.14/receipts/` (135) and `sdk-results/` (28) that quote the
lanes' own environment (`/Users/sac/...`, work-order text). The sweep pattern
targets leaked personal paths, not evidence records — same tolerated class as
`.ggen_igniter/` machine receipts.

## Decisions (counted first)
- **receipts/ + sdk-results/: EXCLUDED** (163 hits / 80 files). Evidence records
  quoting their own environment; scrubbing rewrites historical evidence and the
  volume defeats per-line allowlisting. Directory-level exclusion recorded in
  the sweep header comment with rationale + count.
- **workspace/: NOT excluded — normalized** (4 hits). All four sites reworded
  to repo-relative phrasing (`workspace/...`, "no external analytics services");
  zero residual hits under `workspace/`.
- **17 additional violations surfaced** once exclusions landed — these were
  pre-existing, not introduced. Real fixes, not allowlist padding:
  - `test/sdk-python/run.sh` — `cd "$(cd "$(dirname "$0")/../.." && pwd)"`, `REPO="$PWD"`
  - `test/sdk-python/boot_substrate.py` — `cwd=pathlib.Path(__file__).parents[2]`
  - `smalt-cli/tests/conftest.py` — `REPO_ROOT` derived from `__file__` (2 cwd sites + BOOT_HINT string)
  - `smalt-cli/tests/{test_eventhub,test_keyvault,test_servicebus}.py` — same `REPO_ROOT` seam; mirrored-from comments repo-relative
  - `docs/jira/v26.10.14/ws/README.md`, `smalt-cli/README.md`, `smalt-cli/docs/.../receipts/cli-02-ledger.md` — repo-relative rewording
  - `scripts/naming_sweep.sh` + `scripts/publish_dry.sh` — self-quote surfaces
    (define/run the scan pattern), excluded like `docs/NAMING_SWEEP.md`/`Justfile`.

## Verification
- `bash scripts/naming_sweep.sh` → `[NAMING-SWEEP] PASS: 0 violations / 52 allowed`, exit 0.
- Spot-checked allowed hits are genuinely tolerated classes:
  `.env.example:12,15` (legacy personal defaults, lane 14 owns cleanup),
  `cli/ggen.lock:4` (machine lockfile, regenerated).
- `python3 -m py_compile` on all 5 edited Python files: OK.
- `bash -n` on both edited shell scripts: OK.
- Real-collaborator check: `pytest smalt_cli/test_ledger.py` → 9 passed (conftest
  change compiles and imports cleanly).

## Standing
ALIVE for the gate itself; the functional cwd fixes are compile/import-verified,
not substrate-boot-verified (boot happens under the SDK courts, unchanged).
