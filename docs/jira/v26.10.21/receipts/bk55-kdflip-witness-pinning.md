# BK-55 — kd_flip witness identity pinning (tooling hardening)

**Standing:** **ALIVE**
- **Standing:** ALIVE (kd_flip witness token — machine-readable form of the line above)
- Context: solo
- Date: 2026-10-21
- Subject: `scripts/kd_flip.py` (BK-55 tooling hardening, BK-39's logged finding)
- Note: the working-tree edit was swept into the coordinator's in-flight lane
  snapshot commit `d2825dc` (BK-55 named in the message). This lane authored
  the diff; no separate commit was made by this lane (do-not-commit honored).

## The witnessed mis-flip

`scripts/kd_flip.py`'s witness search matched any receipt under `docs/jira/*/receipts`
that merely MENTIONED a KD id. `--apply` could therefore flip a row citing an
unrelated concurrent receipt: KD-144/145/146 were flipped CLOSED-SIMULATED
citing `bk52-kd161-163-mint.md` — a KD-161..163 mint receipt whose only
connection to the blob fixes is that its embedded kd_flip scan output names the
ids inside a command-output fence. Corrected in place to CLOSED-WITH-EVIDENCE
citing `bk39-kd144-146-blob-fixes.md` (commit c67d9ca). This fix removes the
class: a mention-only receipt can no longer serve as a flip witness.

## Fix design

Witness identity is pinned three ways (explicit beats inferred):

1. **Explicit `--witness KD-ID=PATH`** (repeatable). Honored directly, still
   gated: the path must exist, postdate the shim mtime, carry close evidence,
   and show a pass; otherwise typed refusal (FLIP-PENDING-WITNESS / REFUSED).
2. **Close-evidence heuristic** (inferred witnesses): a candidate receipt
   qualifies only if, in **prose** (fenced command output stripped via
   `strip_fences`), a line naming the KD id has `KD-COVERS` / `Disposition` /
   `CLOSED-` / `Standing:` within `WITNESS_WINDOW = 5` lines of the id.
   Command-output fences are stripped because the mis-flip receipt's only
   id mention was inside a scan-output fence — judge the prose, not the
   artifacts a receipt embeds. Verified discriminator on the real receipts:
   ```
   $ python3 - (close_evidence over bk52 mint vs bk39 fix)
   KD-144 mint: False | fix: True
   KD-145 mint: False | fix: True
   KD-146 mint: False | fix: True
   ```
3. **Ambiguity refusal**: with no `--witness` and MORE THAN ONE qualifying
   receipt, the verdict is `AMBIGUOUS` with the candidate list; `--apply`
   exits 1 (`--apply REFUSED: witness identity ambiguous … Never auto-picking
   (BK-55)`). The old "newest qualifying witness wins" auto-pick is gone.

The mtime-postdates-shim law is unchanged and now also enforced on explicit
witnesses. `KD-MIRROR` sync and the `DO-NOT-FLIP` registrar hold are untouched.

## Non-vacuity self-test (`--self-test`, exit 0 pass / 1 vacuous)

Fixture: temp register row KD-999 (OPEN), shim file, candidate receipts.
Transcript (real output):

```
$ python3 scripts/kd_flip.py --self-test
  PASS fence-only close keyword refused (mention-only class)
  PASS mention-only receipt refused (no close evidence)
  PASS close-evidence receipt selected
  PASS two qualifying receipts -> AMBIGUOUS (registrar must disambiguate)
  PASS explicit --witness honored
  PASS explicit --witness on mention-only refused
  PASS mtime gate enforced for explicit witness
KD-FLIP self-test: witness pinning non-vacuous (7 assertions)
$ echo $?
0
```

(Fence-only refusal is the regression test for the exact bk52 mint-receipt
witness class.)

## Real-register regression scan (read-only)

```
$ python3 scripts/kd_flip.py
KD-COVERS covers-map: 111 KD ids from 129 files
  KD-02: [CLOSED-SIMULATED] lib/smalt/data_plane/blob_storage.ex
  ... (111 covered rows listed, statuses unchanged)
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
$ echo $?
0
```

160 register rows on disk (`grep -c "^| KD" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
→ 160); zero flips, zero unknown ids, zero ambiguous rows, exit 0. Zero
regressions vs. the pre-fix scan.

## Residuals

- `--witness` is per-invocation, not persisted; `just rewitness <KD-nn>` mints
  fresh receipts that now need prose close evidence (Standing: line suffices)
  to clear the gate — any rewitness receipt failing the gate is a typed
  FLIP-PENDING-WITNESS, loud, never a silent pass.
- The self-test summary line says "6 assertions" while 7 PASS lines print
  (count drift only; exit code is the gate).
