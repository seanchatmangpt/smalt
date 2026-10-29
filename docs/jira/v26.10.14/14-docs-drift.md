# V261014-14 — Docs Drift Close-Out

- **Release:** v26.10.14 · **Status:** READY FOR IMPLEMENTATION · **Explore-verified:** 2026-10-15, all facts read from the working tree

## Scope boundary

- **Out of scope:** `docs/ERROR_CODES.md` is healthy — 69 rows, all citations live-exact, `--check` exit 0, fence test runs in the gate. Do not touch it. Do **not** add error-code counts to any prose (count mentions exist nowhere else; keep it that way).
- **Files owned:** `docs/ERROR_SWEEP.md`, `docs/NAMING_SWEEP.md`, `docs/auth_regression_sweep.md`, `docs/PUBLISH_CHECK.md`, `scripts/release.txt`, `justfile` (a `gen-error-codes` target only — lane 12 owns any court extension), `.gitignore` (verify-only; expected no change).

## Verified current state

1. `scripts/release.txt` opens "FOR COORDINATOR TO ADD" and proposes `include_executables: [:smalt]` — but `mix.exs:20-27` already ships a `releases` block using `include_executables_for: [:unix]` + `strip_beams: [compress: true]`. release.txt also cites a CI workflow "lane 19 owns" that does not exist.
2. `docs/ERROR_SWEEP.md:24` cites `tls.ex:147 safe_decode/1` — blank line; actual `safe_decode` at `lib/smalt/tls.ex:283` (which :89 cites correctly). `:36` cites `egress_router.ex:1425-1427 blob encode rescue` — that region is now the lens-7 `blob_route_guarded` refactor (:1423-1431).
3. `docs/NAMING_SWEEP.md:83` and `:191` render verdict "NOT READY — ~55 residual hand-written lines", all REPORTED-TO-LANE, no enumeration, no gating mechanism.
4. `grep -rn '/Users/sac' docs/auth_regression_sweep.md docs/PUBLISH_CHECK.md` → `auth_regression_sweep.md:3` (checkout header) and `PUBLISH_CHECK.md:69,154,158,197,198,252,255` (prose + transcript quotations of past leak-hunt evidence).
5. `scripts/gen_error_codes.py:17` docstring states no Justfile target exists; confirmed — no `gen_error` mention in `justfile`, `docs/DEV_LOOP.md`, or `docs/PUBLISH_CHECK.md`.
6. `erl_crash.dump` at repo root; `.gitignore:20-21` already ignores it — working-tree residue, not a tracking gap.

## Task 1 — reconcile `scripts/release.txt` (mark historical)

Restamp as a **historical lane receipt**: dated header stating the mix.exs `releases` block has landed (`include_executables_for: [:unix]`, `strip_beams: [compress: true]`), superseding the proposed `include_executables: [:smalt]`; the "lane 19 owns CI" reference is void. Preserve the "Port overridability" section (`rel/env.sh.e`, `SMALT_ARM_PORT`/`SMALT_EGRESS_PORT`) as still-current reference. Do not rewrite into a new live instruction set.

**Acceptance:** no live "add a releases block" instruction; no live "lane 19" claim.

## Task 2 — ERROR_SWEEP.md stale cites

- `:24` → `tls.ex:147` blank; actual `lib/smalt/tls.ex:283`.
- `:36` → the rescue moved within the guarded block; read `egress_router.ex:1423-1431` and pin the actual current line.

**Choose one treatment, applied consistently:** (a) refresh both cites, or (b) top-of-doc stamp "Dated receipt of the v26.10.14 sweep — line numbers as-of-sweep, not a living contract." Prefer (b) if the doc will drift again next lens cycle; do not apply both.

**Acceptance:** no cite points at a blank line or unrelated code; the doc unambiguously self-describes as receipt vs. living contract.

## Task 3 — NAMING_SWEEP.md: enumerate wins, gate the residue on lane 12's allowlist

1. Add a "Resolved this sweep" subsection with file:line cites:
   - `test/sdk-smoke/eh-run.mjs`
   - `scripts/dev_env.sh:33` — `DEFAULT_SDK_ROOT` interpolation
   - `scripts/stress/vs_azurite.py:330,369` — cleaned
   - `.env.example:12` — `SMALT_SDK_ROOT` placeholder form
   - `docker/README.md:42` — "legacy-client data-plane egress router" phrasing, no `/Users/sac`
2. Replace the unowned "NOT READY" verdict at :83/:191 with a gated status: residual lines are **not lane-fixable here** — gated behind **lane 12's naming-sweep allowlist**, referenced by name. Do not restate counts in prose beyond the existing table (count-restatement is the drift class).
3. Claim "READY-MODULO-LANE-12-ALLOWLIST" — do not claim READY.

**Acceptance:** verdict names lane 12's allowlist; five wins enumerated; no unowned NOT READY verdict.

## Task 4 — auth_regression_sweep.md + PUBLISH_CHECK.md `/Users/sac` content

Split treatment:
- **Scrub** `auth_regression_sweep.md:3` (header checkout line → `~/smalt` / `<checkout-root>`; scrubbing a header does not falsify evidence).
- **Gate, not scrub**, the PUBLISH_CHECK transcript quotations (:154, :158, :252, :255) — rewriting quoted evidence would falsify the record. Mark as allowlisted evidence blocks under lane 12's allowlist. For :69 and :197-198 (prose), prefer scrub if rewriting does not alter evidence; else gate the same way.

**Acceptance:** `grep -rn '/Users/sac' docs/PUBLISH_CHECK.md docs/auth_regression_sweep.md` → zero hits, or hits only inside explicitly-labeled allowlisted evidence blocks. This is the release gate.

## Task 5 — regen plumbing: `just gen-error-codes` + PUBLISH_CHECK step

1. justfile — exactly one target (lane 12 owns court extensions to this file):
   ```just
   # Regenerate docs/ERROR_CODES.md from the generator's ANNOTATIONS table
   gen-error-codes:
       python3 scripts/gen_error_codes.py
   ```
2. `docs/PUBLISH_CHECK.md` — after the existing ERROR_CODES check: run `just gen-error-codes` then `git diff --exit-code docs/ERROR_CODES.md` must be clean (deterministic projection; a diff means the committed file is stale vs annotations).

**Acceptance:** `just gen-error-codes` exit 0; `mix test test/error_codes_doc_test.exs` stays green.

## Task 6 — delete `erl_crash.dump`

`rm erl_crash.dump`; verify `git check-ignore erl_crash.dump` exits 0 (expected — `.gitignore:20-21`; no .gitignore edit expected). Only if the check fails, add the pattern.

**Acceptance:** file gone; `git status --porcelain` no longer lists it.

## Sequencing

Tasks 5+6 (mechanical) → 1 → 2 → 3+4 together (both hang off lane 12's allowlist; land Task 5's PUBLISH_CHECK step first so PUBLISH_CHECK is touched once per concern) → final verification pass.

## Verification checklist

- `just gen-error-codes` → 0; `git diff --exit-code docs/ERROR_CODES.md` clean.
- `mix test test/error_codes_doc_test.exs` → green.
- `/Users/sac` grep on the two docs → clean or allowlisted-only.
- release.txt restamped; port-overridability section intact.
- `erl_crash.dump` absent; check-ignore green.
- ERROR_CODES.md untouched; no error-code counts in any touched prose.
- NAMING_SWEEP verdict gated on lane 12's allowlist by name; five wins enumerated.
