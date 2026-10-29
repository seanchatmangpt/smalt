# BK-43 — KD-93 registrar close-typing (cosmos query feed read-your-write)

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-21

## Action

KD-93 close-typed **CLOSED-WITH-EVIDENCE**: both earlier faces (the mint's stale
pre-seeded ids `doc_*` and BK-11's pid-1895 phantom id `doc_637510`) were recycled-beam /
stale-projection environment artifacts, not substrate behavior. Two independent live
confirmations agree.

## Independent confirmation probe (BK-43, own, live substrate pid 36590)

Fresh run-unique db `bk43db21792638943`, data plane `http://127.0.0.1:8443`:
db/coll create 201 / doc POST 201 / direct doc GET 200 (`_etag 0b7ca658…` on the first
boot; the first probe rode pid 30317 and succeeded identically before another lane's
restart swapped the beam mid-probe — re-run clean on the new boot).

    POST query SELECT * FROM c WHERE c.mark = @mark (@mark=bk43m) → HTTP 200
      Documents=[bk43doc1] _count=1   ← exactly the just-written doc

Negative controls (all correct):

    @mark=nope                    → _count 0, []
    same filter from a SECOND db  → _count 0, []   (db/coll-scoped)
    SELECT * FROM c (no filter)   → _count 1, [bk43doc1]
    never-seen coll (cX)          → _count 0, []

Falsifier MET: the parameterized query returns the just-written doc, never a pre-seeded
or phantom id. Filter, scope, and freshness are contract-correct.

## Register diff summary

`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` line 276, status cell only (row keeps 6
cells; no pipes added):

- `OPEN (…BK-19 re-typing appended — falsifier MET live, awaiting registrar close-typing)`
  → `CLOSED-WITH-EVIDENCE (registrar close-typing 2026-10-21, BK-43: …)` citing both
  probes (BK-19 pid 47748 / db bk19db1792637265 and BK-43 pid 36590 /
  db bk43db21792638943) + both receipt paths.

## Verification

- `python3 scripts/kd_flip.py` → exit 0, parses the row without skew (covers-map, 108
  KD ids from 126 files; FLIP-ELIGIBLE 0; KD-93 absent from both flip lists — correct,
  no shim exists for it).
- Row cell count re-read post-edit: 6 (`awk -F'|' NR==276 NF-2`), register total
  `^| KD-` rows = 157, unchanged.

## Falsifiers / open residue

- BK-11's opposite face on pid 1895 and the mint's pre-seeded ids did not reproduce on
  two distinct boots — the earlier OPEN typing is attributed to recycled-beam /
  stale-projection environment, disclosed as such in the row.
- No `# KD-COVERS` shim exists for KD-93, so `kd_flip.py --apply` is not applicable;
  the close is registrar-typed directly (same route BK-19 named as the registrar's to
  own).
- Not committed, per dispatch.
