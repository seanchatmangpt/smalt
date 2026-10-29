# BK-26 — KD-14 + KD-23 fix/verify receipt

**Standing:** ALIVE (both rows verified on the live wire; KD-23 fix landed; KD-14 fix already in tree, witnessed)
Context: solo

Date: 2026-10-21. Lane BK-26. Build root `_build-bk26`, Elixir 1.20.4-otp-29.
Substrate: `MIX_BUILD_ROOT=_build-bk26 scripts/substrate.sh up 9>&-` (fd-closed boot,
bounded port polls, no sleeps-as-coordination).

## KD-14 — KV RS256 sign/verify (verdict: CLOSED — contract-correct on the live wire)

Fix provenance: the DigestInfo+`:none` sign/verify path (EMSA-PKCS1-v1_5 over the
SUBMITTED digest, no re-hash) is already in `lib/smalt/data_plane/key_vault_actions.ex`
(`do_sign`/`do_verify`, last landed in 8defcf5). BK-11's `valid:false` witness ran on an
older beam (pid 1895). This lane witnessed the current build; `# KD-COVERS: KD-14` token
added at `do_sign` (comment only).

Live evidence (fresh substrate pid 36590):

- Key `bk26kd14` created: `PUT http://127.0.0.1:8443/KV-route /keys/bk26kd14` (Host:
  `smalt.vault.azure.net`, `x-ms-version: 2024-05-01`) → 200, kid
  `https://smault.vault.azure.net:8443/keys/bk26kd14/328`
- `POST /keys/bk26kd14/sign` `{"alg":"RS256","digest":<b64url SHA-256>}` → 200 with sig
- `POST /keys/bk26kd14/verify` same digest+sig → `{"valid":true,"value":true}`
- **External verifier** (cryptography.hazmat, `Prehashed(hashes.SHA256())`, PKCS1v15):
  - good sig over submitted digest → **TRUE**
  - tampered-signature control (last byte flipped) → **FALSE**
- Deterministic block comparison: recovered RSA block = `0001ff..00 || DigestInfo(digest)`
  — exactly standard RSASSA over the submitted digest; hazmat without Prehashed (hashes
  the digest again) returns FALSE **by harness semantics, not substrate divergence** —
  the earlier "external verify FALSE over both digest and raw" inversion reading in the
  row's 2026-10-16 witness was the same harness artifact: hazmat-plain over the RAW
  message verifies TRUE precisely BECAUSE the substrate signs DigestInfo(digest) = the
  standard RS256 face. The v26.10.16 "Node refuses" note and today's BK-11
  `valid:false` face do not reproduce on the current build.

Falsifier of record (row close condition): external verifier true on the probe flow —
MET via hazmat Prehashed (the digest-level form of Node `crypto.verify('sha256', ...)`
which re-hashes its `data` argument; Node's one-shot API cannot take a pre-hashed
digest, so hazmat-Prehashed is the exact external-verifier equivalent).

## KD-23 — ResourceGraph mixed-form KQL (verdict: FIXED + witnessed)

Two live faces, both closed this lane:

1. **Bare-mixed pipeline 400** — `normalize_pipeline/1` passed any query containing `|`
   through untouched, so `where ... | project ...` hit the parser bare. FIX in
   `lib/smalt/data_plane/resource_graph.ex` (normalize when the trimmed query's first
   word is a pipeline keyword, even when pipes follow) — `# KD-COVERS: KD-23`.
2. **`=~` unsupported** — the falsifier's `where type =~ "..."` answered SYN0003
   ("expected comparison operator after column"): the KQL parser had no `=~`
   (real-KQL case-insensitive equality). FIX in `lib/smalt/data_plane/kql.ex`
   (lexer token + `=~ => :req` + case-insensitive eval) — `# KD-COVERS: KD-23`.

Live evidence (post-fix substrate, seeded resource `bk26acct2`):

- `where type =~ "Microsoft.Storage/storageAccounts" | project id, name` → **200, 2
  records** (the row's falsifier, MET — "200 with records")
- CI-upper control `=~ "MICROSOFT.STORAGE/STORAGEACCOUNTS"` → 200, same 2 records
- Negative control `=~ "microsoft.compute/virtualmachines"` → 200, 0 records
- pipe-leading, bare-only, `order by/take/project` chains → all 200
- Pre-fix controls (same day): bare-mixed → 400 SYN0002; `=~` → 400 SYN0003

Tests: `MIX_BUILD_ROOT=_build-bk26 mix test test/data_plane/kql_test.exs
test/data_plane/resource_graph_test.exs test/integration/kv_ec_create_test.exs`
→ **27 passed, 0 fail** (11 + 16). No pre-existing failures. VERDICT: PASS

## Flips

`scripts/kd_flip.py` read-only scan + `--apply` for KD-14/KD-23 (rows are OPEN, flip
target CLOSED-SIMULATED per tool contract; witness receipt mtime > shim mtime — this
receipt is the witness). Next action after this file: run the flip, re-read register.

## Files touched (lane BK-26)

- `lib/smalt/data_plane/resource_graph.ex` — normalize_pipeline mixed-form fix
- `lib/smalt/data_plane/data_plane/kql.ex` — `=~` operator (note: path is
  `lib/smalt/data_plane/kql.ex`)
- `lib/smalt/data_plane/key_vault_actions.ex` — `# KD-COVERS: KD-14` comment token only
- `docs/jira/v26.10.21/receipts/bk26-kd14-23-auth.md` — this receipt
