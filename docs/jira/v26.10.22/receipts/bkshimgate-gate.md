# BK-SHIMGATE — checkpoint SHIM-COURT gate: `just checkpoint` durable path

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-SHIMGATE
- Closes the BK-B4VW typed process hazard
  (`docs/jira/v26.10.22/receipts/bkb4vw-hardening.md` incident; restore commit
  767b9b52).

## Incident

Coordinator tick checkpoint 44cfa665 staged and landed BK-B4VW's in-flight M2
shim (`# SHIM-COURT BK-B4VW M2`) in
`lib/smalt/messaging/amqp/queue_store.ex` as real code; BK-B4VW fix-forwarded
the restore at 767b9b52. A checkpoint is a bulk `git add`-class sweep over a
shared checkout where lanes legitimately hold in-flight SHIM-COURT-marked
files — the marker is exactly the thing that must never ride a checkpoint
into `lib/`.

## Mechanism

- `scripts/checkpoint_gate.sh` — scans STAGED blob content
  (`git show :path`) of staged ACMR files for the literal marker
  `SHIM-COURT`; prints `checkpoint-gate: REFUSED <file>:<line> carries
  SHIM-COURT marker` per hit and exits 1; prints a clean line and exits 0
  otherwise. Scans the index, not the worktree, so a lane's in-flight
  worktree shim never gates other lanes' clean staging. Exit contract:
  0 clean | 1 refused | 2 usage/git error.
- `justfile.d/54-checkpoint.just` — durable path:
  `just checkpoint <msgfile>` = gate && `git commit -F <msgfile>`;
  `just checkpoint-gate` = gate only. Gate-first ordering means a refused
  gate never invokes git.
- `.git/hooks/pre-commit` not used: session-local-only and the coordinator's
  checkpoints are the exact commits that must be gated — the justfile
  recipe is the durable replacement the coordinator runs instead of bare
  `git commit`.

## Non-vacuity court (Chicago: real git index, temp GIT_INDEX_FILE on HEAD
tree, real files — no mocks)

```
--- code marker staged, expect REFUSE:
checkpoint-gate: REFUSED tmp/shimgate_probe.txt:2 carries SHIM-COURT marker
checkpoint-gate: 1 marker line(s) in staged files — commit REFUSED.
  Strip the markers or unstage the file(s), then retry.
  Register: docs/jira/v26.10.22/receipts/bkshimgate-gate.md
exit=1
--- AFTER (marker stripped, expect PASS):
checkpoint-gate: staged files clean (no SHIM-COURT markers) — OK
exit=0
Re-witnessed after the md exemption (temp index on HEAD tree):

```
--- .exs marker staged            -> REFUSED tmp/shimgate_probe.exs:1, exit 1
--- .md marker + .exs still dirty -> REFUSED (compound: code leg refuses), exit 1
--- .exs stripped, .md marker kept-> staged files clean, exit 0
--- gate script itself staged     -> staged files clean, exit 0
```

Temp index (`git read-tree HEAD` + `git add -f tmp/shimgate_probe.txt` under
`GIT_INDEX_FILE`) so the shared real index was untouched; probe file removed
after (`ls` confirms absent). A gate that accepts the shim would exit 0 on
leg 1 — it does not.

## Landed

Coordinator checkpoint 51d591c7 absorbed the first-draft
`scripts/checkpoint_gate.sh` + `justfile.d/54-checkpoint.just` + `Justfile`
import mid-lane, byte-identical at absorption (gate script sha256
5583ec19b171235bc3068aa9d7f96ed50f237295). This commit carries the receipt
PLUS the md-exemption fix-forward to the gate script (the draft refused this
very receipt); 54-checkpoint.just is unchanged from the absorbed copy.

## Disclosure (compile-freeze SLA)

Mid-lane, `just --summary` failed with "recipe line has extra leading
whitespace" at `justfile.d/53-trivy.just:24` (BK-NISTW3's in-flight file —
mixed 8-space body lines inside a shebang recipe), blocking every recipe
including the new checkpoint ones. Applied the minimal unblock fix
(re-indent >4-space recipe body lines to the 4-space prefix) under the
compile-freeze SLA; the owner's diff itself (scan/receipt recipes) is
lane-owned and left unstaged for BK-NISTW3/coordinator.

## Falsifier

A staged file carrying `SHIM-COURT` that `just checkpoint <msgfile>` commits
anyway (exit 0) falsifies this gate. Witnessed not-firing: leg 1 above,
exit 1.
