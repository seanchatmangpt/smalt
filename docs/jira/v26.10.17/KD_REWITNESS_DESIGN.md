# KD re-witness design note (kd_flip mtime-chain fragility)

Date: 2026-10-17. Author: kd-registrar lane. Status: DRAFT — not implemented;
coordinator approval required before any `scripts/kd_flip.py` change. No
flips, no `--apply`, no git actions performed in this lane.

## Problem statement

`scripts/kd_flip.py` flips a register row OPEN -> CLOSED-SIMULATED only when
a PASS witness receipt (evidence path, or any file under
`docs/jira/v*/receipts/` or the register's `sdk-results/`) mentions the KD id
AND has mtime strictly newer than the newest shim file carrying
`# KD-COVERS: KD-nn` for that id (`witness()` at kd_flip.py:142-172).

The chain dies on any post-witness edit to a covered shim file. Measured this
window: KD-77's witness (`docs/jira/v26.10.16/receipts/lane9-reference-rewrite.md`)
predates this session's edits to
`lib/smalt/messaging/amqp/connection.ex` (KD-77 covers sites confirmed at
`connection.ex:1445` and `connection.ex:2188`; `git status` shows the file
modified), so the gate reads FLIP-PENDING-WITNESS for a row whose behavior
never changed. The same file carries tokens for KD-18, KD-19, KD-20, KD-21,
KD-45, KD-46, KD-49, KD-68, KD-70, KD-71, KD-76, KD-77 — a single incidental
edit to one file resets the mtime clock for a dozen rows at once, and no
re-witness workflow exists.

## Ground truth on the register's falsifier convention

The register table (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) has six
columns: `id | surface | divergence | evidence receipt | close condition | status`.
There is NO falsifier-command column. Falsifiers are embedded as prose inside
the close-condition cell ("falsifier: py probe 04 + ts D1 re-run",
"falsifier: `scripts/shim_court/blocklist_court.sh` PASS", "falsifier:
batch-delete/DLQ settle via azure-servicebus completes without UUID
TypeError"). Quality is mixed: some rows name concrete runnable artifacts
(probe files, court scripts, test file:line); some are outcome prose ("tag
CRUD -> 200 or typed refusal") with no command. Any `--rewitness` mode must
therefore treat the falsifier as: (a) a machine-parseable command convention
introduced additively, or (b) a hand-supplied command named in the receipt —
never silent invention.

## Option A — `--rewitness KD-nn` mode in kd_flip.py

### Design

1. **Falsifier-command convention, additive.** Rows that can be auto-run get
   a fenced inline-code span in the close-condition cell after the literal
   `falsifier:` marker, e.g.
   ``falsifier: `mix test test/data_plane/blob_hardening_test.exs` ``.
   `--rewitness` parses the LAST inline-code span following the literal
   `falsifier:` in the close-condition cell. Absence = not auto-runnable:
   typed skip (exit 3, loud, never a faked pass). No renumbering, no schema
   change; rows without a command keep working exactly as today.

   Rejected sub-option: a side registry (`scripts/kd_falsifiers.json`,
   id -> command) instead of in-table commands. Cheaper to write, but a
   second register drifts from the first by default; keep one source of
   truth in the table.

2. **Dry run / apply.** `--rewitness KD-nn` (read-only): resolve the command,
   print it, exit 0 (found) / 3 (no parseable command — typed skip).
   `--rewitness KD-nn --apply`: preflight (substrate-up check; a probe
   needing the substrate must not cold-boot it silently — self-booting
   harnesses follow the 0/1/2/3 exit contract), run the command, capture
   stdout/stderr + exit code into a fresh receipt
   `docs/jira/v26.10.17/receipts/rewitness-KD-nn-<date>.md` embedding: id,
   command, cwd, substrate state, exit code, real output, and sha256 of each
   covered shim file at run time. On PASS, that receipt is by construction
   newer than every shim mtime (written after reading them), so the existing
   mtime gate clears with zero gate changes. On non-PASS, the receipt still
   lands, marked FAIL, and no gate state clears.

3. **Non-vacuity fences.** (a) mtime-stability check: shim mtimes are read
   before the run and re-read before the receipt write; any change is a typed
   refuse (exit 3) — a concurrent lane edit during the re-witness cannot
   produce a lying receipt. (b) reuse of the existing `shows_pass()`
   negative check (a FAIL/DIVERGENCE row naming the id negates), applied to
   the minted receipt.

### Effort

~80-120 lines in kd_flip.py + a convention note in CLAUDE.md. Half a
lane-day. One file changed.

### Replayability

Medium. The receipt embeds command + cwd + substrate state + exit code +
output + shim sha256s, so replay is a manual re-run of the recorded command;
comparison is by verdict. But mtime remains the load-bearing fact — mtimes
are transport state, not identity, and are not clone-portable.

### Failure modes

- **Command rot**: probe renamed / route moved. Detected at next --rewitness
  as exit 3 typed skip — designed behavior, not a silent pass.
- **Concurrent edit during run**: fenced by the mtime-stability check (typed
  refuse; re-run required).
- **Does not fix the disease**: every incidental connection.ex touch still
  resets ~12 rows. Recovery becomes one command instead of archaeology, but
  the resets keep happening and each recovery mints a receipt (INDEX.md
  growth; mitigated by the `rewitness-*` naming so `just receipt-index`
  keeps working unchanged).

## Option B — C21-shape: subject-keyed receipts outside the tree (git notes)

### Design

Witness receipts are minted as git notes on `refs/notes/kd-witness`,
attached to the commit that landed the KD-COVERS token, so the witness chain
is keyed on SHAs, not filesystem mtimes. kd_flip replaces the mtime
comparison with: does a PASS-witness note exist on the token-landing commit
or any descendant? The token-landing commit is located mechanically per
(id, file) via `git log -S 'KD-COVERS: KD-77' --format=%H -- <file>`
(pickaxe; bounded at this repo's history size).

**Descendant rule**: a witness note on the landing commit or any descendant
clears the id. An incidental edit to connection.ex that keeps the token is a
new commit on the descendant chain — the chain stays valid. Only a
revert/reword of the token itself re-opens the chain, which is exactly the
right semantics: the cover claim re-opens only when the commit history
actually loses the claim. This directly fixes the KD-77 invalidation: the
session's connection.ex edits kept the token, so under B the row stays
cleared.

### Effort

High. (1) A note-minting step — but note minting is a WRITE to a shared ref,
and the same-checkout fanout law says agents never run git state commands;
the coordinator owns transitions. So minting must be coordinator-owned at
integration: probe runs in-lane and lands a normal receipt FILE, coordinator
mints the note from the file at integration. This resolves the law conflict
but delays machine-readable witness existence by one integration cycle.
(2) `just receipt-index` must learn to index notes (or index both). (3)
kd_flip reads notes instead of (or transitionally in addition to) mtimes.
(4) Docs/convention updates across CLAUDE.md + rules. (5) Unpushed notes are
invisible cross-clone — the coordinator must push `refs/notes/kd-witness` at
integration, and receipt-index should report unpushed note SHAs as a loud
state.

### Replayability

Best of the two. SHA-keyed, clone-portable (notes travel with the ref on
push/fetch), mtime-free, content-addressed; a third party re-runs the probe
at the pinned SHA and compares to the note. Per operating doctrine, content
(SHA) is identity; mtime is transport. B replaces transport with identity.

### Failure modes

- **Fanout-law friction**: note minting is a git write to a shared ref;
  must be coordinator-owned at integration, delaying witness existence by
  one integration cycle (witness-as-file exists in-lane immediately, but the
  machine-readable chain clears only post-integration).
- **Two-store drift**: file receipt + note must agree, unless the note IS
  the receipt (file becomes a pointer or the note content = file content).
  That dedupe is its own design decision needing its own work order.
- **Unpushed-note invisibility**: the new analog of stale mtime — a local
  fact other clones cannot see. Needs a loud check (receipt-index reporting
  unpushed note SHAs).
- kd_flip gains a git subprocess dependency; pickaxe cost is bounded at this
  repo's size but nonzero.

## Honest comparison

| | A: --rewitness | B: git-notes (C21 shape) |
|---|---|---|
| Kills mtime as load-bearing? | No — recovery is one command, but every incidental connection.ex touch still resets ~12 rows | Yes — content-keyed; incidental edits do not re-open the chain; only token revert/reword re-opens it |
| Effort | Low (~100 lines, one file, no workflow change) | High (notes workflow, receipt-index changes, coordinator flow, docs) |
| Replayability | Medium — receipt embeds command+output+shim sha256s; replay is a manual re-run | High — SHA-keyed, clone-portable, mtime-free |
| Failure modes | Command rot -> typed skip; concurrent edit -> typed refuse; resets keep happening, recovery just gets cheap | Unpushed-note invisibility; coordinator-owned minting delays witness; two-store drift unless note IS the receipt |
| Fixes the reported KD-77 invalidation? | Recovery only — the next connection.ex touch invalidates again | Yes — the edits kept the token, so the chain stays valid under B |
| Change/approval surface | kd_flip.py + CLAUDE.md convention note | kd_flip.py + receipt-index + coordinator git flow + conventions docs |

## Recommendation

**A first, B as the end state.**

- A is a mechanical recovery tool for the current law: one file, half a
  lane-day, reuses `shows_pass()` and the existing receipt flow, and gives
  this window an immediate `--rewitness KD-77` recovery command. Its cost is
  that incidental touches keep resetting the clock and each recovery mints a
  receipt.
- B fixes the disease but crosses the fanout law (note minting = git write
  to a shared ref, so coordinator-owned at integration) and requires
  receipt-index + coordinator-flow changes. The "note IS the receipt" dedupe
  is a real design decision that deserves its own work order and its own
  falsifier (e.g. an unpushed-note invisibility probe with a typed refusal),
  not a rider on this note.
- A is not throwaway when B lands: --rewitness still has to run the
  falsifier command parsed from the register and produce the PASS output;
  only the minting step changes shape (file -> note). A becomes B's
  probe-runner.

Sequence: land A now; open a follow-up work order for B with the note-is-
receipt dedupe and the unpushed-note loudness check as named acceptance
criteria.
