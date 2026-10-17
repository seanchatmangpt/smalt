# Receipt — R152 (KV court CA anchoring)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

Session-listed as "kv court CA anchoring, exit 0". The covering court is
`scripts/shim_court/kv_challenge_court.sh` — BEFORE (no CA anchoring) fails the
handshake, AFTER (anchored) completes, restore sha256-verified. No R152 literal
marker exists on disk; receipt written from the session-verified subject list
plus a fresh court run.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ scripts/shim_court/kv_challenge_court.sh
[court] final restore + sha256 verify
[court] RESTORE VERIFIED (sha256)
[court] VERDICT: BEFORE_RC=1 AFTER_RC=0 RESTORE_OK=0
[court] PASS: BEFORE fails, AFTER handshake completes, restore sha256-verified
[court] restore (trap)
exit=0
```

## W10 re-run (2026-10-16, docs lane W10)

```
$ just shim-court kv_challenge
[court] private substrate UP (AFTER): arm=60557 egress=60558 tls=60559
[witness:BEFORE] HANDSHAKE_FAIL RestError: MissingBearerToken
[witness:AFTER] HANDSHAKE_OK kd15-chal kid=present
[court] RESTORE VERIFIED (sha256)
[court] VERDICT: BEFORE_RC=1 AFTER_RC=0 RESTORE_OK=0
[court] PASS: BEFORE fails, AFTER handshake completes, restore sha256-verified
EXIT=0
```

Standing: PASS.
