# Receipt — signing.key rotation (execution lane ROTATE)

- Date: 2026-10-15 · Subject: /Users/sac/smalt @ main 518b31a (uncommitted lane edits)
- Authority: coordinator rotation decision; per
  `docs/jira/v26.10.14/receipts/11-publish-blockers.md` + `docs/PUBLISH_CHECK.md`.
- Seed bytes: NOT RECORDED here by design. New seed sha256 prefix: `fa9ea5ea45923395`.

## Actions

1. New 64-hex ed25519 seed generated (`openssl rand -hex 32`); matching public
   key derived (python `cryptography`, Ed25519). Sign/verify round-trip
   witnessed: PASS.
2. Key pair installed at BOTH copies, chmod 600:
   - `/Users/sac/smalt/cli/.ggen/keys/signing.key` + `verifying.key`
   - `/Users/sac/smalt/test/fixtures/runtime_contracts/ggen/.ggen/keys/signing.key` + `verifying.key`
   (fixture had no `.ggen/` post-X-lane — created mirroring the
   `cli/.ggen/keys/` layout; a `.gitignore` matching `cli/.ggen/keys/.gitignore`
   should accompany it.)
3. Old-seed eradication: `grep -rI "<old-seed-first-16-hex>" --exclude-dir=.git .`
   → zero hits (grep exit 1). Old seed sha256-of-seed prefix: `47ceeabb9070fcc9`
   (read from old key pre-rotation for the witness only).
4. Receipt chain: **ROTATION-PENDING-SIGNATURE**. ggen IS available
   (`/Users/sac/.local/bin/ggen`), but rebuilding the chain requires re-running
   the original `ggen sync` against the original ontology/manifest state —
   not reproducible byte-identical here, and NOT faked. Old chain bytes in
   `cli/.ggen-v2/` and `test/fixtures/runtime_contracts/ggen/` left intact;
   `ROTATION-NOTE.md` header note added to both directories.
5. `scripts/publish_dry.sh` + `justfile.d/08-publish-dry.just` summary line
   updated: "publish released pending final court-x2 (rotation EXECUTED
   2026-10-15)" (was "publish gated on: signing.key rotation").
6. `docs/PUBLISH_CHECK.md`: appended verdict
   "rotation EXECUTED 2026-10-15; publication unblocked pending final court-x2".
7. `docs/ERROR_CODES.md` regenerated (gate 4 had flagged line-number drift
   from lane edits; 24 lines re-synced). Pre-existing drift, not
   rotation-introduced — cleared as fix-forward.

## Verification (real output)

- `mix test test/runtime_contracts_test.exs` → **28 tests, 0 failures**
  (cross-anchor fence green post-rotation; it pins BLAKE3 hashes of generated
  files, not key signatures).
- `just publish-dry` → **all 4 gates PASS, exit 0**:
  - gate 1 hex.build: PASS (310784 bytes)
  - gate 2 inner-tar key grep: PASS (0 matches)
  - gate 3 packaged-set leak grep: PASS (0 hits)
  - gate 4 ERROR_CODES regen identity: PASS
- Key-file perms witnessed: `-rw-------` (600) on all four key files.

## Standing / falsifiers

- Rotation: ALIVE (keypair round-trip + eradication grep + gates above).
- Receipt chain: ROTATION-PENDING-SIGNATURE — ALIVE-use, retired-signature.
  Falsifier: a court that verifies chain signatures against the new
  verifying.key will refuse the old-signed chain until re-synced.
- No commits made (per lane contract).
