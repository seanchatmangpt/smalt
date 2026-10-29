# Receipt — DoD-08 publish dry-run gate

- Date: 2026-10-15 · Subject: /Users/sac/smalt @ main 3fc2543 (uncommitted lane edits)
- Owns: `scripts/publish_dry.sh`, `justfile.d/08-publish-dry.just` (recipe `publish-dry`)

## What was built

`scripts/publish_dry.sh` — productizes lane 11's packaging fix
(`receipts/11-publish-blockers.md`). Four automatable gates, fail-closed
(exit 0 only if all pass):

1. `MIX_ENV=test mix hex.build -o <out>` — tarball build, same command as lane 11
   (docs/PUBLISH_CHECK.md v1 transcript; lane 11 used
   `mix hex.build -o /tmp/hex-lane11/smalt.tar`).
2. Inner-tar key gate: `tar -xzOf <tarball> contents.tar.gz | tar -tz |
   grep -cE "signing.key|verifying.key|\.ggen|keys/"` must be 0; on failure the
   offending paths are listed.
3. Packaged-set leak grep over the unpacked contents with the PUBLISH_CHECK
   3a / naming-sweep pattern class: `legacy-client|/Users/sac` — zero hits required.
4. `python3 scripts/gen_error_codes.py --check` — docs/ERROR_CODES.md regen
   identity.

Summary block ends with the explicit line
`publish gated on: signing.key rotation (coordinator decision)`.

`justfile.d/08-publish-dry.just` defines `publish-dry`, imported by the root
`Justfile` (line 219). Note: `just -f justfile.d/08-publish-dry.just` alone
defaults cwd to the justfile's dir — use `just --justfile justfile.d/
08-publish-dry.just --working-directory /Users/sac/smalt publish-dry`, or
`just publish-dry` from the root once the unrelated parse error in
`justfile.d/03-cli-wiring.just:71` (unknown token `.` — pre-existing, not
this lane's file) is fixed.

## Verification (real output)

`just --justfile justfile.d/08-publish-dry.just --working-directory
/Users/sac/smalt publish-dry` → exit 0:

```
-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 301056 bytes; log: /tmp/hex-publish-dry/smalt.tar.build.log)
-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)
-- gate 3: packaged-set leak grep (pattern: legacy-client|/Users/sac)
   PASS (0 hits in packaged set at /tmp/hex-publish-dry/smalt.tar.unpacked)
-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)
== summary ==
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
publish gated on: signing.key rotation (coordinator decision)
```

## Standing / falsifiers

- Packaging gate: ALIVE (witnessed run above).
- Key rotation: PENDING — coordinator-owned (burned seed shipped in v2 tarball
  bytes); not a gate failure, stated explicitly in the summary line.
- Pre-existing, not this lane's: `just publish-dry` via root Justfile currently
  aborts parsing `justfile.d/03-cli-wiring.just:71`; also `git diff` shows
  docs/ERROR_CODES.md already modified pre-session (working tree is
  self-consistent: `--check` passes).
- No commits made (per lane contract).
