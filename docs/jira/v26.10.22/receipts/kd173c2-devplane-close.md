# Receipt: KD-173C2 — post-close verification + BK-N7 cleanup-race fix (KD-173)

- Standing: ALIVE
- Context: solo
- Date: 2026-10-22
- Lane: KD-173C2

## Disposition (overlap disclosed)

KD-173 was closed concurrently by the KD-173C lane mid-session: its receipt
`docs/jira/v26.10.22/receipts/kd173c-devplane-close.md` landed 05:44 and its
register flip (KD-173 -> CLOSED-SIMULATED, witness = that file) was applied
while this lane was diagnosing kd_flip refusals (the sibling's disclosed
`--only` ambiguity-scoping fix to `scripts/kd_flip.py` landed between this
lane's runs — explains the verdict flip mid-session; `--self-test` green,
10 assertions, re-verified by this lane post-landing). The canonical close,
the gate code, and the register row are the sibling lane's; this receipt does
not supersede it.

This lane's independent delta, verified on the post-close tree:

## 1. BK-N7 cleanup-race fix (this lane's code change)

`workspace/scripts/e2e-court.mjs` (final tmp cleanup): `fs.rmSync(tmp, ...)`
raced lingering handles from the just-killed lane `next dev` servers and could
throw ENOTEMPTY/EBUSY/EPERM after a green verdict. Fix per BK-N7: catch those
codes, bounded 10s retry loop (setImmediate, no sleeps), then leave the dir on
disk with a loud `# CLEANUP-LEAK: ...` line — never a silent leak, never a
fake pass. Also removed the prior lane's stray `# DEBUG` console line from the
leg-5 boot calls (kept the `killA()/killB()/killC()` call-shape).

## 2. Post-close verification (real server legs, current tree)

`just ws-lint`: clean. `node workspace/scripts/e2e-court.mjs` (exit 0),
embedded output:

```
[PASS] live: ingest default key refused off dev plane — POST /api/v1/ingest default-key sig -> 503 dev_default_key_refused
[PASS] live: ingest default key admitted on dev plane — POST /api/v1/ingest default-key sig (SMALT_DEV_PLANE=1) -> 202 accepted
[PASS] live: ingest provisioned key admitted off dev plane — POST /api/v1/ingest provisioned-key sig -> 202 accepted

# court verdict
# PASS=73 FAIL=0 SKIP=2
```

Both ways witnessed on real `next dev` servers (39751/39752/39753): env off ->
default key rejected typed 503; env on -> default key admits 202 (posture
preserved); provisioned key admits 202 off the dev plane. KD-173 close
condition met and re-witnessed post-flip.

## Register

KD-173 row: CLOSED-SIMULATED, witness
`docs/jira/v26.10.22/receipts/kd173c-devplane-close.md` (sibling lane's flip;
verified on disk this lane). This lane ran no flip; its earlier flip attempt
was refused by the then-current ambiguity gate and superseded by the
sibling's successful apply.
