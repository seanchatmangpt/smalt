# I8 — substrate.sh key-guard shim verification

Standing: PASS (report-only; no substrate booted, no git)

Lane I8, lease `scripts/substrate.sh` + `justfile.d/*substrate*`. The working
tree carries a SHIM-COURT key-guard diff (lines 194–203 of
`/Users/sac/smalt/scripts/substrate.sh`): warn when `SMALT_SB_SHARED_KEY`
unset; hard-refuse when `SMALT_FAIL_ON_DEFAULT_SB_KEY=1`; fall back to the
pinned dev default `ws8sharedkey` otherwise. Marker `SHIM-COURT` present at
lines 65 and 195.

## Verification

### 1. Syntax gate

```
$ bash -n /Users/sac/smalt/scripts/substrate.sh && echo "SYNTAX_OK exit=$?"
SYNTAX_OK exit=0
```

### 2. Report-only status (`just substrate-status`)

```
[STATUS] port 9443: UP (pid 99281)
[STATUS] port 9444: UP (pid 99281)
[STATUS] port 5672: UP (pid 99281)
[STATUS] port 5673: free
[STATUS] substrate DOWN
[STATUS] lock FREE (flock -n succeeds)
substrate-status exit=0
```

Exit 0. The command is report-only: it boots nothing and takes no lock
(lock FREE confirmed). The guard code path is not exercised by boot here by
design — lane law forbids booting a substrate on canonical ports (9443/9444/
5672 partially held by a pre-existing pid 99281, substrate DOWN, lock FREE —
pre-existing state, not introduced by this lane).

## Guard semantics (read-verified, lines 196–203)

- unset `SMALT_SB_SHARED_KEY` → stderr WARNING, continues with pinned default.
- `SMALT_FAIL_ON_DEFAULT_SB_KEY=1` and unset → `REFUSED` to stderr, then
  `return 1 2>/dev/null || exit 1` (correctly handles both sourced and
  executed invocation).
- set `SMALT_SB_SHARED_KEY` → guard skipped, `SB_KEY` uses it verbatim.
