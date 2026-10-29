# KD-FIXF — register prose repair (F1/F2/F3 forward-fix)

**Standing:** **PASS**
Context: solo
Date: 2026-10-22
Lane: KD-FIXF (registrar lane; edited only the two KD register docs + this receipt)

Tasked from `receipts/kdskep-register-audit.md` findings F1/F2/F3. Disk truth
re-verified fresh before every edit (KD-171 had flipped CLOSED-WITH-EVIDENCE
via `kd171r-secret-gate.md` since the audit pinned ~05:10, so F1 applies to
KD-169/173/174 only; KD-171 needed only its F3 shim-sentence fix).

## Per-row edits (falsifier: corrected cell matches disk)

```
$ grep -n "KD-COVERS: KD-169" lib/smalt/webpubsub/router.ex
27:  `# KD-COVERS: KD-169`          # working tree, router.ex git-modified (KD-169R in flight)

$ grep -n "KD-COVERS: KD-171" workspace/lib/caller-gate.ts
3:// KD-COVERS: KD-171

$ grep -n "KD-COVERS: KD-172" lib/smalt/messaging/amqp/sas_verifier.ex
190:  # KD-COVERS: KD-172

$ grep -rn "KD-COVERS: KD-173" workspace/app/api/v1/ingest/route.ts
(no match — KD-173 "KD-COVERS shim: none yet" remains TRUE; left standing)
```

- **F2 — KD-172 (canonical + window)**: evidence cell corrected from
  "KD-COVERS shim: none yet ... carries `# KD-COVERS: KD-171`" to the disk
  truth: `lib/smalt/messaging/amqp/sas_verifier.ex:190` carries
  `# KD-COVERS: KD-172` (KD-173R repair; receipt `kd173r-audience-repair.md`).
  The wrong-id + none-yet text was renumber-era prose lag.
- **F3 — KD-171 (canonical + window)**: "KD-COVERS shim: none" corrected to
  `workspace/lib/caller-gate.ts` `# KD-COVERS: KD-171` (KD-171R; called from
  `workspace/app/api/sync/state/route.ts`).
- **F3 — KD-169 (canonical + window)**: "shim: none yet" corrected to
  "landing in flight (KD-169R)" — the router.ex token IS on disk but the file
  is uncommitted (KD-169R lane owns it), so a landed-absolute would be the
  same class of false. Disposition appended (owner = KD-169R lane; next
  action = off-host witness receipt then flip via kd_flip.py --apply).
- **F1 — KD-173 (canonical + window)**: Disposition triple appended (owner =
  BK-BFFSEC follow-up lane; next action = boot-refuse/503 when
  `SMALT_INGEST_HMAC_KEY` unset on a non-dev plane + real server leg proving
  a default-key signature rejected, then flip). Close condition (falsifier)
  already present; unchanged. "none yet" verified still true on disk.
- **F1 — KD-174 (canonical + window)**: Disposition triple appended (owner =
  BK-122r kafka-parity lane; next action = advertise Produce v3+ with v3
  record shapes, witness a real client negotiating magic-2 produce, then
  flip — else re-register posture).
- **F1 scope note**: KD-171 was OPEN at audit time, now CLOSED-WITH-EVIDENCE
  — no disposition needed (re-verified fresh before edit, per task).

## Gates after edit (real output)

```
$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 309 receipt cites across 6 registers -> OK
fence-exit=0

$ python3 scripts/kd_flip.py   # read-only
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 2 (KD-168, KD-169 mention-only refused)
WITNESS-AMBIGUOUS: 1 (KD-174, 2 candidate receipts)
flip-exit=0
```

Pending/ambiguous rows are the tool's documented loud-not-flipped standing;
no flips were applied (not this lane's authority). Residue grep for the old
false sentences: exit 1 (zero matches).

## Off-row observation (not edited — other lanes' files)

`lib/smalt/egress_router.ex` and `lib/smalt/arm_gateway/router.ex` carry
`# KD-COVERS: KD-174` tags (EXPL-9 F2 / EXPL9-R2 F1 crash-path fences), but
KD-174 is the Kafka magic-2 produce row and its row names
`lib/smalt/messaging/kafka/` as the shim locus — no kafka file carries the
token. The EXPL9-R1/R2 egress/arm guard shims appear mis-tagged to KD-174;
their owners should retag (or the row's locus sentence should widen). Left
untouched: those files belong to the EXPL-9 lanes. Noted also by kd_flip's
KD-174 WITNESS-AMBIGUOUS entry citing expl9r1/expl9r2 receipts.

## Standing

PASS — all six register prose cells corrected to disk truth, KD-169/173/174
OPEN rows now carry the full falsifier+owner+next-action disposition triple,
gates green after edit (309 cites OK, flip exit 0 loud-pending).
