# i29 — push-readiness audit (main vs origin/main), 2026-10-18

Standing: ALIVE.
Context: solo. Read-only audit; no mutations, no push.

## Command

```
$ git log origin/main..main --oneline | cat   # 10 commits, dda0bf5..44b0859
$ just publish-dry
```

## Per-commit audit

Patterns grepped per commit diff (read-only `git show <sha>`): `/Users/sac` literals,
`signing.key`, `BEGIN [A-Z ]*PRIVATE KEY`, `(PASSWORD|SECRET|TOKEN)=`.

| SHA | Subject | Files | /Users/sac hits | Secret-pattern hits | Verdict |
|---|---|---|---|---|---|
| 44b0859 | fix(naming): naming-sweep repair — 0 violations / 47 allowed (was 76/41) | 25 | present (receipts/docs paths) | 0 | CLEAR |
| 6eec145 | docs(test): sovereign-gap triage — un-tag 5 deterministically-passing bodies, keep typed exclusion for 5.3 ARG KQL only | 65 | 111 (docs/receipts paths) | 0 (signing.key line = publish-dry's own grep pattern, quoted prose) | CLEAR |
| 0009df3 | fix(test): sovereign_midnight require path + typed :sovereign_gap exclusions for G1-G6 | 103 | 49 (docs/receipts paths) | 0 | CLEAR |
| dda0bf5 | fix(test): azure_common_issues require path — `__DIR__` relative, not nonexistent /burn-evidence | 7 | 1 (docs path) | 0 | CLEAR |
| 219469d | feat(have): components 4/10/12 — telemetry emitter, runbook, guard-ledger mirror | 2 | 2 (docs paths) | 0 | CLEAR |
| b668f1c | feat(have): components 5/8/13 — alert jidoka engine, Petri conformance, docs integration | 18 | 13 (docs paths) | 0 | CLEAR |
| efd8e1c | feat(have): components 1/3/6 landed + docs-audit D1-D15 corpus + sleep-gate burn scope | 18 | 15 (docs paths) | 0 | CLEAR |
| d848a3b | feat(have): components 2-3 telemetry + ratchet mod R1-R8 tests + AZB-19 re-witness residue | 6 | 9 (docs paths) | 0 | CLEAR |
| 7511a54 | feat(azsim): AZB-15 plane DR kills — identity STS gate + 4-scenario court | 4 | 2 (docs paths) | 0 | CLEAR |
| c67de30 | feat(have): HAVE engine components 1-2 + ratchet mod tests + AZB-19 re-witness | 313 | 11 (docs paths) | 3 benign: (1) test writes dummy `-----BEGIN PRIVATE KEY-----` fixture; (2) `SMALT_TOKEN=` extracted at runtime from emulator's own STS, no literal; (3) `docs/jira/v26.10.18/burn/.../ggen/.ggen/keys/signing.key` fixture = one hex sha256 test fixture, not a real key | CLEAR |

Findings detail (c67de30): the signing.key fixture content is
`0b605bdc2aa12598073747a5f150ee774b555465724d5bdc31593dd6900b1ce0` — a single
hex string test fixture for the burn harness, not a PEM private key. All
`/Users/sac` hits are in `docs/jira/**` receipts (paths inside receipt prose),
which publish-dry gate 3 confirms are excluded from the packaged hex set.

## publish-dry at HEAD (44b0859)

```
== publish dry-run gate: /Users/sac/smalt ==
-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 793088 bytes)
-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)
-- gate 3: packaged-set leak grep (pattern: legacy-client|/Users/sac)
   PASS (0 hits in packaged set)
-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
EXIT=0
```

## Verdict

READY — 10/10 commits clear; all `/Users/sac` literals confined to
`docs/jira/**` receipt prose (excluded from the packaged set, gate 3 PASS);
no private keys, signing keys, or secret literals in any diff; `just
publish-dry` exits 0 at HEAD.

Scope note: this is the push-readiness gate only — release still requires
court-x2 per the wrap sequence.
