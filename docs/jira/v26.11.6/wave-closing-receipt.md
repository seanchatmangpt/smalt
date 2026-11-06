# Wave-closing receipt — smalt, v26.11.6 closure (lane R-SMCLOSE)

Standing: PASS

Date: 2026-11-06 · Lane: R-SMCLOSE · Repo: /Users/sac/smalt (Elixir, elixir
1.20.4-otp-29 via asdf) · Owner files: this receipt +
`docs/jira/v26.11.6/open-items.md` only.

## What smalt contributed to v26.11.6

- **Cosmos verb law fix (KD-G19)** — commit `97cc1cc9` "fix(cosmos): sign
  uppercase verb in master-key string-to-sign (KD-G19)": real Azure Cosmos
  signs the verb as transmitted (uppercase); smalt's
  `lib/smalt/data_plane/cosmos/auth.ex` previously HMAC'd a lowercase atom,
  rejecting arcus-minted signatures. Witnessed by two new test files under
  `test/data_plane/`: `cosmos_auth_verb_case_test.exs` (uppercase pinned,
  lowercase sig rejected) and `cosmos_auth_cross_repo_test.exs` (arcus-minted
  fixture validates via `valid_master_sig?/6`, string-to-sign byte-equality
  both sides).
- **Uppercase witness court** — `cosmos_auth_verb_case_test.exs`, 3 tests.
- **Cross-repo handshake court** — `cosmos_auth_cross_repo_test.exs` (2
  tests, fixture-gated on `KD_G19_FIXTURE`); driven by
  `/Users/sac/arcus/scripts/kd_g19_handshake.sh`, which mints the fixture in
  arcus (Go) and runs the smalt validation leg. KD-G19 flipped PARTIAL →
  CLOSED in arcus's `KNOWN_DIVERGENCES.md` (see arcus
  `docs/jira/v26.11.6/kd-g19-handshake-receipt.md`, Standing: PASS).
- **Source faces arcus ported (wf corpus cells)** — arcus v26.11.6 receipts
  cite smalt as the port source for: KeyVault keys/crypto lifecycle face
  (`kvcrypt-receipt.md`), Cosmosql face (`cosmosql-receipt.md`), Service Bus
  auth rules (`cbs3-receipt.md`), Event Hubs checkpoint-store face
  (`ehckpt-receipt.md`), Monitor.Metrics (`errc11-receipt.md`).
- Broader wave context: 33 receipt files under `docs/jira/v26.11.6/receipts/`
  (AoQ epoch/replication, kafka wire, sigv4/blake3, port law, S19 verdict
  ladder); wave-receipt-overnight-1 Standing: PARTIAL_ALIVE; final-per-repo
  Standing: PARTIAL_ALIVE.

## Gate evidence re-run this session (real exits)

Toolchain: asdf Elixir 1.20.4-otp-29 / Erlang 29.1.2 (matches
`.tool-versions`; system elixir 1.19.5 refuses the project — `~> 1.20`
declared). Build root: `MIX_BUILD_ROOT=_build-smclose`.

| Gate | Command (cwd /Users/sac/smalt) | Exit | Result |
|---|---|---|---|
| Verb-case witness court | `mix test test/data_plane/cosmos_auth_verb_case_test.exs` | 0 | 3 passed, 0 failed |
| Cross-repo handshake (full court, arcus driver) | `bash /Users/sac/arcus/scripts/kd_g19_handshake.sh` | 0 | `PASS: smalt validation leg` / `KD-G19 handshake: PASS (both legs)`; runs the 2 cross-repo tests with `KD_G19_FIXTURE` set → 2 passed |
| Cross-repo tests without fixture (documented gate-on-env behavior) | `mix test test/data_plane/cosmos_auth_cross_repo_test.exs` (no env) | 1 | 0/2 passed — both `flunk("KD_G19_FIXTURE env var must point at the arcus mint fixture")` — loud skip, not a fake pass |

Not re-run (per lane contract): the AAD network files
(`test/integration/cosmos_aad_auth_header_test.exs`,
`test/integration/redis_wire_entra_auth_test.exs`) — pre-existing failures,
registered as open items, not fixed by this lane.

## Verification ladder

Narrow (pure crypto asserts) → integration (cross-repo handshake over a real
mint fixture on real transport) — both green, exits cited above.
