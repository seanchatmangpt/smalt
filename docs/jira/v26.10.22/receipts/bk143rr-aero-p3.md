# BK-143rr — aero-defense P3 proposer-judge (v26.10.22)

**Standing:** ALIVE
Context: solo
Date: 2026-10-22

Closed the last open pillar cell (aero P3 proposer-judge, BK-143r
relaunch). Pack: `ggen-marketplace/packs/industry-aero-defense/`.

## Gate

`gates/070_proposer_judge.rq` — ASK refusal: any `ad:AIContribution`
with `ad:proposes` lacking `ad:adjudicatedBy` → `ad:JudgeActivity`
refuses. New ontology terms: `ad:AIContribution`, `ad:JudgeActivity`,
`ad:proposes`, `ad:adjudicatedBy` (extends the pack's execution-proof
surface; mirror of IND-2's 060 pattern).

## Witnesses

- pass: `witnesses/pass/070_proposer_judge.ttl` — adjudicated
  contribution over a fully-lawful classified scene; 0 rows under ALL
  7 gates.
- fail: `witnesses/fail/070_proposer_judge.ttl` — adjudication by a
  plain prov:Activity; only gate 070 fires, gates 010-060 silent
  (exactly-one-law, enforced by the runner contract).

## Court output (python3 qualification/verify.py, exit 0)

14/14 cells PASS, standing ALIVE. Cells: 010/020/030/040/050/060/070
pass+fail pairs all PASS. 070 fail verdict PASS = gate fires on the
fail witness and ONLY gate 070 (runner refuses more-than-one-gate).

Consumer: `examples/industry/aero-defense/consumer` `ggen sync run`
exit 0; `output/pillar-gates.md` byte-identical across two runs
(sha1 match, replay witness above).

## Files

- packs/industry-aero-defense/ontology.ttl (P3 terms)
- packs/industry-aero-defense/gates/070_proposer_judge.rq
- packs/industry-aero-defense/witnesses/{pass,fail}/070_proposer_judge.ttl
- packs/industry-aero-defense/templates/pillar-gates.md.tmpl
- packs/industry-aero-defense/PILLARS.md (new)
- examples/industry/aero-defense/consumer/* (pin + output)

Not committed (lane handoff per task contract).
