# r244 — B1 CLOSED: ex4pm hex-only resolution + smalt package builds green

Standing: PASS
Date: 2026-10-17
Context: solo

## Chain

1. ex4pm 26.10.8 published to hex (operator action; hex tarball checksum on
   record in mix.lock).
2. smalt mix.exs flipped hex-only: `{:ex4pm, "~> 26.10.8"}` (override dropped —
   hex.build refuses overridden deps; no conflict in prod scope since
   ash_ex4pm is dev/test-only), `{:ash_ex4pm, "~> 26.10.1", only: [:dev, :test],
   optional: true}`.
3. mix.lock resolves `ex4pm 26.10.8` from `:hexpm`, checksum
   `d507fd16e89795eac781c47bad22542fd8196558ab15eb6d8b38c7fd92450fd2`
   (= the G1 dry-build verification checksum).
4. `mix hex.build -o /tmp/hex-smalt-test.tar` → exit 0, package checksum
   `88210b0195614bf2014369d230c6083ea98cb7c07883a9fa769e85d520455fd9`.

## publish-dry (full, this tree)

```
-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS
-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)
-- gate 3: packaged-set leak grep (pattern: athena|/Users/sac)
   PASS (0 hits in packaged set at /tmp/hex-publish-dry/smalt.tar.unpacked)
-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)
== summary ==
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
```

## Disposition

- PUBLISH_RECORD.md B1: CLOSED (addendum per
  docs/jira/v26.10.17/PUBLISH_RECORD-B1-CLOSED.addendum.draft.md, applied).
- Publish gates 2-4 were already green; gate 1 was the sole B1 blocker and is
  now witnessed green.
- Remaining release gate: court-x2 two-green (attempt 4 queued after the i21
  repair wave's verification receipts).
