# Receipt — V261014-11 (publish blockers, lane 11)

- Date: 2026-10-15 · Subject: /Users/sac/smalt @ main 3fc2543 (uncommitted lane edits)
- Decision (c) hybrid executed. Key rotation NOT performed (coordinator-owned).

## File work

1. Deleted (rm -rf, coordinator commits):
   - `lib/smalt/runtime_contracts/ggen/.ggen/` (signing.key 64-hex ed25519 seed, verifying.key, .gitignore)
   - `lib/smalt/runtime_contracts/ggen/.ggen-v2/` (dir now empty after receipt move)
2. Moved `receipt.json` + `receipt-log.jsonl` → `test/fixtures/runtime_contracts/ggen/`.
3. `test/runtime_contracts_test.exs`: receipt_path → `test/fixtures/runtime_contracts/ggen/receipt.json`.
4. `mix.exs` package/1 comment corrected: exclude_patterns are dead-by-design
   (hex matches per-files:-entry; `**` no dot-dir traversal; keys lack .pem).
   Gate = physical tree + tar-grep, not glob semantics. `files:` unchanged.
5. `docs/PUBLISH_CHECK.md`: v2 blocker row, v3 section-1.1 row, v3 remaining-blockers
   row marked RESOLVED-for-packaging; new v4 section with gate output; verdict
   PUBLISH-READY YES (packaging), rotation pending (coordinator).

## Verification (real output)

- `mix test test/runtime_contracts_test.exs` → **28 tests, 0 failures**
  (cross-anchor fence green with relocated receipt).
- `mix hex.build -o /tmp/hex-lane11/smalt.tar` → exit 0,
  checksum `b3f377cd86287191cf38e0181935a78bd54e1964af8af27c67b62bf67cc363d9`.
- Inner-tarball gate:
  `tar -xzOf /tmp/hex-lane11/smalt.tar contents.tar.gz | tar -tz | grep -cE "signing.key|verifying.key|\.ggen|keys/"` → **0** (was 5; grep exit 1 = zero matches).

## Standing / falsifiers

- Packaging gate: ALIVE (receipted above).
- Key rotation: PENDING — coordinator-owned; burned seed already shipped in v2
  tarball bytes. Old-seed-prefix tree grep deferred to the rotation step.
- No commits made (per lane contract).
