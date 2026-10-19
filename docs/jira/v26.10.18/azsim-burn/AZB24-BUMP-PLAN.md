# AZB-24 Release Mechanics — Bump Plan (DRAFT, not applied)

Status: DRAFT — plan only, zero diffs applied. Coordinator lands at the gate.
Context: solo.

## 1. Current version surface (as-of 2026-10-18, read from disk)

| Surface | Current | Target |
|---|---|---|
| `mix.exs` `@version` | `26.10.16` | `26.10.18` |
| `workspace/package.json` `version` | `26.10.14` | `26.10.18` |
| `CHANGELOG.md` head | `## [Unreleased]` then `## [26.10.16] - 2026-10-16` | insert `## [26.10.18] - 2026-10-18` under `## [Unreleased]` |
| semanticEpoch | derived: `lib/smalt/projection/canonical.ex:94` reads `Mix.Project.config()[:version]` | no hand edit — regen after mix.exs bump |

Note: `package.json` is at 26.10.14 (two versions behind mix.exs at 26.10.16 —
pre-existing skew, mixed on bump to 26.10.18 in this same pass).

## 2. Exact diff plan

### 2.1 mix.exs

```diff
--- a/mix.exs
@@ -4 +4 @@
-  @version "26.10.16"
+  @version "26.10.18"
```

### 2.2 workspace/package.json

```diff
--- a/workspace/package.json
@@ line 3
-  "version": "26.10.14",
+  "version": "26.10.18",
```

### 2.3 semanticEpoch regen (generated, never hand-edit)

```bash
mix run -e 'Smalt.Projection.Canonical.write()'
```

Reads the new `@version` (via `Mix.Project.config()[:version]` at
`lib/smalt/projection/canonical.ex:94`) and rewrites `docs/capabilities.json`
(+ THIRD_PARTY.md rider) with `semanticEpoch: 26.10.18`. Verify with
`git diff --stat docs/capabilities.json` — expected single-line semanticEpoch
change.

### 2.4 CHANGELOG.md

Insert under `## [Unreleased]` (blank line after it), above the existing
`## [26.10.16] - 2026-10-16` heading:

```markdown
## [26.10.18] - 2026-10-18

AZB burn wave over the v26.10.16 surface. Highlights (receipts:
docs/jira/v26.10.18/RECEIPTS.md):

- Sovereign Midnight 18/18: all 18 bodies run untagged
  (`:sovereign_gap` tag retired), `mix test test/azsim/sovereign_midnight/sovereign_midnight_test.exs`
  → 18 tests, 0 failures (azsim-burn/SOVEREIGN_MIDNIGHT.md refresh 2026-10-18).
- AZB-17 parallel plane matrix ALIVE: N containers × 4 planes
  (receipts/azb-17-parallel-matrix.md).
- Zombie face closed: AZB-22b ZOMBIE_BEAM Owner-EXIT face + Bandit shutdown
  bounds, verify receipt ALIVE (receipts/azb-22b-zombie-fix.md,
  receipts/azb-22b-zombie-verify.md).
- Naming + leak gates green: tree GREEN 0 offenders
  (commit 4106990; receipts/i29-env-leak-remediation.md).
- KD-98 registered (witness receipts/i29-a22f1-witness.md,
  i29-checkpoint3.md).
- G1–G4 carried to v26.10.19 (azsim-burn/G1-QUEUE-STORAGE-SCOPING.md).

### Fixed

- (enumerate per-window fixes at land time — placeholder, coordinator fills
  from final RECEIPTS.md ordering)
```

### 2.5 Order of application

1. mix.exs + package.json (single commit or same wave; package.json line 3 only).
2. `mix run -e 'Smalt.Projection.Canonical.write()'` — regen semanticEpoch.
3. CHANGELOG entry.
4. Mint release receipt (§3).
5. Proceed to wrap sequence (§4).

## 3. AZB-24 mint command (placeholder SHAs)

Script: `scripts/mint_release_receipt.py` (exists; argparse verified lines 125-146).
Args: `--sha` (required), `--refusals` (required), `--court-log` (required);
defaults: `--release v26.10.16` → must pass `--release v26.10.18`;
`--exit-code` required-effective (default -1 = pending; pass the real court-x2 exit).

```bash
python3 scripts/mint_release_receipt.py \
  --sha <RELEASE_SHA> \
  --refusals <REFUSALS_JSON_PATH> \
  --court-log <COURT_LOG_PATH> \
  --release v26.10.18 \
  --ref main \
  --command "just court-x2" \
  --exit-code 0 \
  --standing "ALIVE: two-green court-x2 at <RELEASE_SHA>" \
  --court-standing PASS \
  --type RELEASE_ADMISSION_COURT
```

Placeholders: `<RELEASE_SHA>` = post-bump release head (minted only AFTER the
bump commit lands — a commit cannot contain its own hash, so this is the
child-of-bump commit SHA); `<REFUSALS_JSON_PATH>` / `<COURT_LOG_PATH>` =
court-x2 run artifacts under `tmp/` (scratch; the minted receipt is durable,
the logs are not).

## 4. Final wrap sequence with current evidence paths

Per CLAUDE.md wrap order:

1. **WOs land per dependency order** — work orders:
   `docs/jira/v26.10.18/azsim-burn/TICKETS.md` (AZB ticket set); burn docs
   `azsim-burn/AZB23-PREFLIGHT.md`, `azsim-burn/SOVEREIGN_MIDNIGHT.md`.
2. **Receipts** — `docs/jira/v26.10.18/RECEIPTS.md` (index) +
   `docs/jira/v26.10.18/receipts/*.md` (azb-11-isolation-court,
   azb-11b-leak-remediation, azb-17-parallel-matrix, azb-22b-zombie-*, i29-*).
3. **GAP sweep** — `docs/WIRE_PARITY.md` GAP tokens; no GAP-closing receipts
   in this window's receipts/ listing; KD rows live in root
   `docs/KNOWN_DIVERGENCES.md` (KD-98 witnesses: receipts/i29-a22f1-witness.md,
   receipts/i29-checkpoint3.md).
4. **court-x2** — recent attempts: `receipts/i29-court-dry1..4.md`,
   `receipts/i29-court-rehearsal.md`; terminal two-green receipt is minted at
   step 5 and linked from FINAL.md (not yet written).
5. **Regenerate all generated artifacts** (then) — `just receipt-index`,
   `just bench-report`, `docs/ERROR_CODES.md` via `just gen-error-codes`,
   semanticEpoch via §2.3, then `just docs-dod-check` (0 MISS expected).
6. **commits** — per-lane atomic commits, `git commit -F <file>`; coordinator-owned.
7. **publish-dry** — `just publish-dry` (tarball leak greps + ERROR_CODES
   identity); recent green evidence: commit 8b7cbcd receipt chain.
8. **FINAL.md** — `docs/jira/v26.10.18/FINAL.md` (does NOT exist yet — write at
   wrap; planning handoff pointer to v26.10.19 with the carried G1–G4 items,
   see `azsim-burn/G1-QUEUE-STORAGE-SCOPING.md`).
9. **RECEIPTS.md** — `docs/jira/v26.10.18/RECEIPTS.md` regenerated via
   `just receipt-index` at the final step (generated, never hand-edit).
