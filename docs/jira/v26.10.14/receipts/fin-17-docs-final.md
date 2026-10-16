# fin-17 — final docs truth-sync (DoD-only finish lane)

Date: 2026-10-15. Subject: /Users/sac/smalt (uncommitted; no commits per lane contract).
Scope: CHANGELOG.md `[Unreleased]`, README "Workspaces & Tooling", DoD-12 docs gate.

## Changes

1. `CHANGELOG.md` `[Unreleased]`, tooling list:
   - Enclave-testbed bullet updated: 9 phases, 9 PASS (2026-10-15, run.sh
     exit 0); ENCLAVE-1 dispositioned RESOLVED-INVALID with the Azure
     semantics (new blobs writable into locked/legal-hold containers; only
     overwrite/delete of existing blobs refused, 409 `ContainerLocked`).
     Receipt-linked: `sdk-results/enclave-testbed.md`.
   - New finish-wave line: landed DoD recipes `court-x2`, `publish-dry`,
     `verify-all`, `sdk-matrix`, `substrate-up`/`substrate-down`/
     `substrate-status`, plus `gap-sync`, `receipt-index`, `doctor-dod`,
     `lane-clean`; receipt-linked (`dod-01`, `dod-07`, `dod-08`, `dod-09`,
     `dod-14`, `dod-12`, this receipt).
2. `README.md` "Workspaces & Tooling":
   - Enclave bullet: added current standing (9/9 PASS).
   - New "DoD tooling" bullet naming the landed entry points. Every recipe
     name verified against `just --list` output before naming
     (`court-x2 publish-dry verify-all sdk-matrix substrate-up
     substrate-down substrate-status doctor-dod gap-sync receipt-index
     docs-dod-check lane-clean` — all present; `docs-dod-check` is defined
     in `justfile.d/12-docs-dod.just`, imported by the root Justfile).
3. `justfile.d/12-docs-dod.just` (minimal unblock fix, disclosed): DOCS_ROOT
   was unreliable — under `import`, `justfile_directory()` is the repo root,
   so `parent_directory()` overshot to `/Users/sac` and bare
   `just docs-dod-check` went 9/9 MISS (pre-existing defect, exit 1 before
   this lane). Re-anchored on `git rev-parse --show-toplevel` from the
   working directory, with a downward search fallback for non-git use.

## Verification (DoD-12 docs gate)

- Before fix: `just docs-dod-check` -> 9/9 MISS, exit 1 (pre-existing).
- After fix:
  - `just docs-dod-check` -> 9/9 OK, exit 0.
  - `just --justfile justfile.d/12-docs-dod.just docs-dod-check` -> 9/9 OK,
    exit 0 (both invocation styles, since DOCS_ROOT now varies by style).

## Standing

ALIVE (docs surface): every receipt path named in user-facing docs exists on
disk, 9/9 witnessed. Falsifier: `just docs-dod-check` returning any MISS.
