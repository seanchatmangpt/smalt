# Lane 37 — Residue-to-Green Integration Ledger (coordinator script)

Status: **ALIVE** — every path referenced below verified on disk 2026-10-30.
This file is the only write this session; no deletions or edits were performed.

Subjects: `/Users/sac/smalt` (canonical checkout; all integration edits except
the consumer-side README row) and `/Users/sac/cai/courtroom-platform-az`
(consumer README + this ledger). One canonical checkout per repo; coordinator
owns all git transitions; commits via `git commit -F <file>`; never reset,
never worktrees.

## 0. Verified deltas vs. the dispatch brief (read before running)

1. **`receipts/INDEX` does not exist.**
   `smalt/docs/jira/posh/v26.10.30/receipts/` has no INDEX; the register that
   exists is `gaps/INDEX.md` (23 rows, per-file status quoted). The brief's
   "receipts/INDEX refresh" resolves to: CREATE `receipts/INDEX.md` new, plus
   refresh the 01/09/13 rows of `gaps/INDEX.md`.
2. **`KD-01` does not exist in the posh window.** KD rows in this window are
   `KD-POSH-1/5/6` in the `notes` array of
   `receipts/parity/posh009-coverage-gate-green.json` (KD-POSH-1 is already a
   line-ref flip). The role_definition divergence row is **G1 in
   `gaps/01-provider-azurerm-parity.md`** (status BLOCKS-CONSUMER). D2/C1
   reconciliation targets G1 + the posh009 notes + the courtroom README row —
   not a nonexistent KD-01.
3. **gaps/09 re-runnable claim is at line 37**, not 63–65 as gaps/13 R6a cites.
   Fix `gaps/09-courts-matrix.md:37` and optionally the stale citation inside
   gaps/13.
4. **Two lease roots beyond the G18 census**: `_build-final` (754M) and
   `_build-lane23` (381M). Full deletion set is ~5.5G, not ~4.4G.
5. **`/tmp/posh*` is ~44 files** (logs, .pgo, test binaries, scratch dirs),
   not 3. All deletable. KEEP only the REPO-relative
   `smalt/tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`
   (`/tmp/posh/` and `smalt/tmp/posh/` are different trees).
6. **`smalt/gaps/` does not exist.** The only relocation is
   `courtroom-platform-az/gaps/24-cross-repo-skew.md` →
   `smalt/docs/jira/posh/v26.10.30/gaps/24-cross-repo-skew.md` (24 is the next
   free number; its header already names both repos). After relocation,
   courtroom `gaps/` holds only this lane-37 file.

Verified inventory (G18 census + extras, sizes re-read this session):
`_build` 754M KEEP (live beam) · `_build-c4` 754M · `_build-f4` 373M ·
`_build-f5` 754M · `_build-f9` 754M · `_build-f12` 381M · `_build-final` 754M ·
`_build-lane23` 381M · `/tmp/f2-provider` 413M · `/tmp/f3-provider` 170M ·
`/tmp/f3` 728M.

## Phase A — deletions first (ERRC: delete outranks generate)

```sh
set -e
cd /Users/sac/smalt

# A1 (B) — liveness gate over ALL lease roots. Expect: silent, exit 0.
# Any "LIVE:" line aborts the wave.
for d in _build-c4 _build-f4 _build-f5 _build-f9 _build-f12 _build-final _build-lane23; do
  lsof +D "$d" >/dev/null 2>&1 && { echo "LIVE: $d"; exit 1; }
done

# A2 (B) — G13 tombstone hard-delete. Expected: exit 0.
# NOTE: untracked dir; no git action. BEFORE: `test -d` exits 0.
rm -rf /Users/sac/smalt/terraform-provider-smalt

# A3 (B) — G13 closes: POSH-007 falsifier re-run. Expect: silent, exit 0.
test ! -d /Users/sac/smalt/terraform-provider-smalt \
  && test -s /Users/sac/smalt/tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz

# A4 (B) — G18 lease deletion (lane-lease law: leases deleted at integration).
rm -rf _build-c4 _build-f4 _build-f5 _build-f9 _build-f12 _build-final _build-lane23

# A5 (B) — /tmp residue. Expect silent.
rm -rf /tmp/f2-provider /tmp/f3-provider /tmp/f3 /tmp/f16_after.txt /tmp/f16_plan_err.txt
rm -f  /tmp/posh_client.py /tmp/posh_flip_* /tmp/posh_gate_out.txt /tmp/posh_green.txt
rm -f  /tmp/posh_main_restored.go /tmp/posh-bench-* /tmp/posh-boot.log /tmp/posh-c11*
rm -f  /tmp/posh-c11-sha*.txt /tmp/posh-c12-bin /tmp/posh-cpu.pgo /tmp/posh-cpu2.pgo
rm -rf /tmp/posh-c11 /tmp/posh-debug*.log /tmp/posh-dry.* /tmp/posh-finalbuild
rm -f  /tmp/posh-ggen-head.toml /tmp/posh-gobuild /tmp/posh-nopgo /tmp/posh-p2
rm -rf /tmp/posh-pgo /tmp/posh-q*.log /tmp/posh-real*.* /tmp/posh-render2
rm -f  /tmp/posh-tail.just /tmp/posh.test /tmp/posh2.test /tmp/poshrun

# A6 (B) — verify deletion set. Expect: silent, exit 0.
for d in _build-c4 _build-f4 _build-f5 _build-f9 _build-f12 _build-final _build-lane23; do
  test ! -e "$d" || { echo "RESIDUE: $d"; exit 1; }
done
test ! -e /Users/sac/smalt/terraform-provider-smalt
du -sh /tmp/f2-provider /tmp/f3 /tmp/posh* 2>/dev/null  # expect: no matches
```

## Phase B — doc fixes (G13 residue, gaps/09, design.md)

| # | Step | File / edit | Expected | B |
|---|---|---|---|---|
| B1 | 57 archive-stub guard | `smalt/justfile.d/57-tf-provider.just`: insert at top of every recipe that runs the kind ladder (and in `_check_provider_tools` or a shared prereq), before the ladder: `test -f terraform-provider-smalt/README.md \|\| { echo "[TF-ARCHIVED] spike dir archived; GA path is just posh-court"; exit 4; }` — post-A2 the dir is gone so the guard must fire on the ARCHIVED branch by design; guard text should read: `test ! -e terraform-provider-smalt && { echo "[TF-ARCHIVED] Elixir spike archived (POSH-007). GA path: just posh-court (58-posh.just)"; exit 4; }` i.e. if the spike dir is PRESENT, refuse with a tombstone-mismatch message; if ABSENT, exit 4 immediately | `just provider-court-elixir` exits 4 with `[TF-ARCHIVED]` on stderr before any kind/kubectl call; `just provider-court` (deprecated alias) same | B |
| B2 | design.md:273 | replace tree-diagram line `` `terraform-provider-smalt/`  # provider (POSH-004, dev_overrides) `` with `adapters/terraform-provider-smalt/` | root spike no longer listed as live provider | B |
| B3 | design.md:356 | replace "Existing capital: `/Users/sac/smalt/terraform-provider-smalt/scripts/schema_inventory_gate.py`" with the archive tarball path `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz (schema_inventory_gate.py archived)` or the Go-provider equivalent if one exists on the adapters tree | no pointer to a deleted path | B |
| B4 | gaps/09:37 | `smalt/docs/jira/posh/v26.10.30/gaps/09-courts-matrix.md` line 37: replace "re-runnable via `just provider-court-elixir`" with "NOT re-runnable post-archival; `just provider-court-elixir` exits 4 `[TF-ARCHIVED]` (guard added in 57-tf-provider.just); the spike court is re-runnable only from the archive tarball" | claim matches post-A2 behavior | B |
| B5 | gaps/13 R6a | optionally update gaps/13's stale "09:63-65" citation to "09:37" | citation accurate | NB |

Guard ordering note for B1: the brief says "exit 4 **before the kind ladder**"
with the falsifier being that the dir is gone. Confirmed shape: with the
tombstone hard-deleted (A2), any 57 recipe's first act must be the
`[TF-ARCHIVED]` exit-4 refusal — the guard keys on `test ! -e
terraform-provider-smalt` relative to `TFROOT`, placed as the first recipe
body line of `provider-build` / `provider-install` / `provider-court-elixir` /
`provider-court` / `provider-status`.

## Phase C — G19 glossary landing

```sh
# C1 (B) — land the glossary from gaps/19's bilingual table (12 rows) +
# multi-meaning table (5 terms) + missing-artifact register.
# Source of truth: smalt/docs/jira/posh/v26.10.30/gaps/19-vocabulary-drift.md §1–§3.
# Destination (verified ABSENT before write — creating, not overwriting):
#   smalt/docs/jira/posh/v26.10.30/glossary.md
```

Edit shape: new file `smalt/docs/jira/posh/v26.10.30/glossary.md`, H1
`# posh v26.10.30 Glossary`, three H2 sections mirroring gaps/19 §1 (bilingual
glossary, 12 rows, verbatim term/artifact/divergence columns), §2 (multi-sense
terms), §3 (missing-artifact register). Do not paraphrase the file:line anchors
— copy them verbatim (they were verified this session by lane 19). Status
line: PARTIAL per gaps/19's own header (four charter terms have no artifact;
INVARIANT SPARQL has no runtime engine). After write:
`grep -c '^|' glossary.md` ≥ 19 table rows.

## Phase D — D2/C1 reconciliation (role_definition)

Verified current state:
- Provider: role_definition support code EXISTS in the Go provider
  (`adapters/terraform-provider-smalt/internal/provider/resource_remaining_v1.go`
  referenced by arm_client/import/live/honesty tests; `roleDefinitions` PUT/DELETE
  present per the G1 close condition). grep hits confirm the resource family.
- Courtroom `README.md:131` still says: "`azurerm_role_definition` gaps |
  Resource is UNSUPPORTED on smalt (see gaps/01...)" — STALE.

| # | Step | Command / edit | Expected | B |
|---|---|---|---|---|
| D1 | Confirm support before flipping any row | `grep -n "roleDefinitions\|role_definition" /Users/sac/smalt/adapters/terraform-provider-smalt/internal/provider/resource_remaining_v1.go \| head` and run the provider's role_definition tests: `cd /Users/sac/smalt/adapters/terraform-provider-smalt && go test ./internal/provider/ -run 'RoleDefinition\|ImportState' -count=1` | grep shows roleDefinitions CRUD; tests exit 0 | B |
| D2 | Courtroom README row → LIVE | `courtroom-platform-az/README.md:131`: replace the UNSUPPORTED row with: `\| azurerm_role_definition gaps | RESOLVED v26.10.30 — roleDefinitions implemented on the smalt Go provider (see gaps/01 G1 close) \|` | row no longer claims UNSUPPORTED | B |
| D3 | gaps/01 G1 row | flip status BLOCKS-CONSUMER → CLOSED (roleDefinitions landed; cite the D1 test receipt) — and append `KD-POSH-7 (role_definition: UNSUPPORTED → implemented)` to the `notes` array of `receipts/parity/posh009-coverage-gate-green.json` | G1 closed with receipt citation | B |
| D4 | (if coverage gate exists) | re-run the posh009 coverage gate so the JSON regenerates with the new note: `python3 scripts/posh_coverage.py` | exit 0 | NB |

## Phase E — registers / receipts refresh

| # | Step | Edit | Expected | B |
|---|---|---|---|---|
| E1 | Create `smalt/docs/jira/posh/v26.10.30/receipts/INDEX.md` | new file: one row per receipts/ entry (dflss_audit_receipt.json, final-wave-receipt.md, lease-cleanup.md, measure/, migration/, mutation/, parity/, posh-court/, schema_parity_live.md, wave2-membrane-receipt.json) with one-line standing each, re-read from disk | file exists, covers all 10 entries | B |
| E2 | Refresh `gaps/INDEX.md` | update rows 01 (G1 CLOSED), 09 (re-runnable claim corrected; 57 guard landed), 13 (CLOSED — tombstone deleted, falsifier passes) | 3 rows match Phase A–D outcomes | B |
| E3 | Refresh `receipts/final-wave-receipt.md` | append an integration section: Phase A deletion receipts (bytes freed, falsifier exit 0), Phase B–D edit list, and correct/annotate the PARTIAL Gate-1 verdict (internal/andon `andon_test.go:203 skip must hold YELLOW, got GREEN`) with its current status — re-run `cd posh && go test ./internal/andon/ -run TestHoldOnSkipAndBlocked -count=1` before writing | receipt reflects post-integration truth; if the andon test still fails, record it as the wave's open defect, do NOT round up | B |

## Phase F — relocation sweep

```sh
# F1 (B) — move the stray consumer-root lane report into the posh window.
mv /Users/sac/cai/courtroom-platform-az/gaps/24-cross-repo-skew.md \
   /Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/24-cross-repo-skew.md
# Expected: courtroom gaps/ contains ONLY 37-residue-to-green-ledger.md;
# smalt gaps/ has 01–24 + INDEX.md (24 reports + index).

# F2 (NB) — sweep confirmation:
ls /Users/sac/cai/courtroom-platform-az/gaps/
ls /Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/ | wc -l   # expect 25 (24 + INDEX)
test ! -e /Users/sac/smalt/gaps                               # expect exit 0
```

## Phase G — final commit/push sequence (coordinator-owned, serialized)

```sh
# G1 (B) — smalt integration commit. Write message to a file first; never -m.
cd /Users/sac/smalt
cat > /tmp/37-smalt-commit-msg.txt <<'EOF'
Integrate v26.10.30 posh wave: residue deletion + G13/G19 close + registers

- Delete Elixir-provider tombstone (POSH-007 falsifier passes; 57-tf-provider
  recipes now exit 4 [TF-ARCHIVED] before the kind ladder)
- Fix design.md:273/:356 archived-provider references; correct gaps/09:37
- Land glossary.md (G19) from gaps/19; refresh gaps/INDEX.md rows 01/09/13
- Close G1 role_definition (README row LIVE; KD-POSH-7 note in posh009)
- Add receipts/INDEX.md; refresh final-wave-receipt integration section
- Relocate 24-cross-repo-skew.md from consumer root into the gap register

Lane-lease roots (_build-c4/f4/f5/f9/f12/final/lane23) deleted at integration
per same-checkout-fanout cleanup law; ~5.5G freed.
EOF
git add -A
git commit -F /tmp/37-smalt-commit-msg.txt
# Expected: single commit; no _build-* dirs staged (they are deleted, and any
# strays must fail G1 of Phase A). If git status shows _build-* or tmp/posh/
# archive changes, STOP and investigate before committing.

# G2 (B) — consumer commit (courtroom-platform-az): README row + this ledger.
cd /Users/sac/cai/courtroom-platform-az
cat > /tmp/37-consumer-commit-msg.txt <<'EOF'
Mark azurerm_role_definition RESOLVED in README; add lane-37 integration ledger

Consumer-side reconciliation for the smalt v26.10.30 posh wave: the smalt Go
provider now implements roleDefinitions, so the README gap row flips from
UNSUPPORTED to RESOLVED. gaps/37-residue-to-green-ledger.md is the wave's
integration checklist receipt.
EOF
git add README.md gaps/37-residue-to-green-ledger.md
git commit -F /tmp/37-consumer-commit-msg.txt
# Note: the consumer tree also carries pre-existing modifications
# (.github/workflows/infra-dev.yml, .gitignore, infra/...lock.hcl, scripts/)
# that are NOT lane 37's — add only the two lane-37 paths above.

# G3 (B) — push both.
git -C /Users/sac/smalt push
git -C /Users/sac/cai/courtroom-platform-az push
# Expected: both exit 0, no force, no rebase.

# G4 (NB) — post-commit verification:
test ! -d /Users/sac/smalt/_build-c4 && test ! -d /Users/sac/smalt/_build-final
git -C /Users/sac/smalt status --porcelain | grep _build   # expect: no output
git -C /Users/sac/cai/courtroom-platform-az status --porcelain | grep -v '^ M .github\|^ M .gitignore\|infra/\|scripts/\|package' | head
```

## Falsifier (non-vacuity for this ledger)

A lane-37 court that accepts the shim is vacuous: after Phase A, re-run the
POSH-007 falsifier (A3) — if `terraform-provider-smalt/` still exists OR the
archive tarball is missing, the wave is not green regardless of any commit
success. Symmetrically, `just provider-court-elixir` must exit 4 (not 0, not
3): an exit 0 after deletion means the guard never landed (B1 shim never
fired); an exit 3 means the tool check ran before the guard (ordering bug).
