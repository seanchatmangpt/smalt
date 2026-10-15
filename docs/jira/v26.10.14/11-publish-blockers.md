# V261014-11 — Publish blocker: ggen signing.key ships in hex tarball

- **Release:** v26.10.14 · **Status:** OPEN — sole hard blocker (`docs/PUBLISH_CHECK.md`: PUBLISH-READY **NO**)
- **Owner:** release coordinator (rotation timing coordinator-owned; file edits owned by this work order)
- **Files owned:** `mix.exs`, `lib/smalt/runtime_contracts/ggen/.ggen` tree, `lib/smalt/runtime_contracts/ggen/.ggen-v2` tree, `docs/PUBLISH_CHECK.md`, `cli/.ggen/` (note only — unpackaged)

## 1. Blocker (explore-verified 2026-10-15)

The hex package ships private key material. Five leak paths survive in every build, under `lib/smalt/runtime_contracts/ggen/`:

| Path | Content |
|---|---|
| `.ggen/keys/signing.key` | 64-hex ed25519 **seed** (private) |
| `.ggen/keys/verifying.key` | matching public key |
| `.ggen/keys/.gitignore` | gitignore for the key pair |
| `.ggen-v2/receipt.json` / `receipt-log.jsonl` | receipt chain with signature hex strings |

**Why the existing exclusion never fires.** `mix.exs:60-69` sets `files: ~w(lib priv ...)` with `exclude_patterns: ["**/.ggen/**", "**/keys/**", "**/*key*.pem"]`. All three patterns are dead:

1. hex glob matching is applied **per-`files:`-entry, relative to that entry** — cross-entry `lib/**` traversal is not how the matcher resolves `**`;
2. `**` does not traverse into dot-directories, so `.ggen` is invisible to every pattern;
3. the keys have no `.pem` extension, so `**/*key*.pem` cannot match.

Verified against a real build (lens-8): fresh `mix hex.build` rc=0, inner `contents.tar.gz` contains all 5 paths:

```
tar -tzf contents.tar.gz | grep -cE "signing.key|verifying.key|\.ggen|keys/"   # => 5, expected 0
```

(Grep the INNER tarball listing, not the outer wrapper.)

**Impact scoping — dev artifact, not a runtime dependency.** smalt's runtime does NOT load this key: real receipt signing is RSA, lazily generated (`trust_profile.ex:577-600`, `security/receipt_signer.ex:6,155`); `config/config.exs:13` sets `receipt_signing_key: nil`. Deletion/relocation breaks no runtime behavior. However, **rotation is required regardless of which fix lands** — the seed already shipped in the v2 tarball bytes and is burned.

## 2. Decision gate — pick ONE primary fix

- (a) Relocate fixtures out of `lib/` to `test/fixtures/runtime_contracts/ggen/` (outside `files:`). Clean; moves the tree + test paths.
- (b) Fix `exclude_patterns` to a hex-matching form. Fragile — glob semantics under-documented; must be verified against a real build; silently regresses if hex changes matching.
- (c) **RECOMMENDED: delete + relocate-one-pair hybrid.** The only in-repo consumer of the receipt chain is the cross-anchor fence test (`test/runtime_contracts_test.exs:411`), which reads `.ggen-v2/receipt.json`'s BLAKE3 pins over the *generated* files — not the key — so rotation + re-sign does not change the pins. Concretely:
  1. `git rm -r lib/smalt/runtime_contracts/ggen/.ggen lib/smalt/runtime_contracts/ggen/.ggen-v2`.
  2. Regenerate the v2 receipt chain under the NEW key; place the rebuilt `receipt.json` + `receipt-log.jsonl` at `test/fixtures/runtime_contracts/ggen/`; update the path at `test/runtime_contracts_test.exs:411`.
  3. Keep `exclude_patterns` edits OUT of the acceptance path (optional belt-and-suspenders only, verified against a real build; the gate must not depend on glob semantics). Also correct the inaccurate B6 comment at `mix.exs:63-65`.
- Fallback: if regenerating the receipt chain proves non-trivial, use (a) wholesale — move the entire `.ggen{,-v2}` tree unregenerated, then rotate keys in place there and in `cli/.ggen/keys/`.

## 3. Unconditional key rotation (coordinator-owned timing; deliberate post-window)

1. Generate a NEW 64-hex ed25519 seed.
2. Write it to BOTH locations: `cli/.ggen/keys/signing.key` and the (relocated or rebuilt) fixture location.
3. Derive and overwrite `verifying.key` in both from the new seed.
4. Rebuild the `.ggen-v2` receipt chain signed with the new key; confirm the BLAKE3 `outputs` pins are byte-identical (they pin generated files, not the key) so the cross-anchor fence still passes.
5. Confirm zero hits for the OLD seed's first 16 hex chars across the checkout: `grep -rI "<old-seed-prefix16>" --exclude-dir=.git .` → no output.

## 4. Verification / acceptance gate (hex.build)

```sh
mix hex.build
tar -xzOf <tarball> contents.tar.gz | tar -tz | \
  grep -cE "signing.key|verifying.key|\.ggen|keys/"    # expect 0 (was 5)
grep -rI "<old-seed-prefix16>" --exclude-dir=.git .    # expect no output
mix test test/runtime_contracts_test.exs               # cross-anchor fence green
```

**hex.build acceptance:** inner `contents.tar.gz` listing contains zero matches; tests green including the cross-anchor fence describe-block.

## 5. Documentation updates

- `docs/PUBLISH_CHECK.md` — rewrite the blocker (lines ~186-192, ~249, ~292-297): mark RESOLVED with the tar-grep output as evidence; flip the verdict to PUBLISH-READY **YES** once the gate passes.
- `cli/.ggen/` — note that `cli/.ggen/keys/` is an unpackaged dev-only key copy, rotated, and that hex packaging never includes `cli/` (absent from `files:`).

## 6. Sequencing

1. Coordinator confirms the rotation window (post-v2 tarball; deliberate, not emergency).
2. Rotate keys (§3.1-3).
3. Delete `.ggen`/`.ggen-v2` from `lib/`; rebuild the receipt chain at the relocated path; update the test path.
4. `mix hex.build` + tar-grep gate; tests.
5. Update `docs/PUBLISH_CHECK.md`; flip verdict.
