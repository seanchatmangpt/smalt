# Known Divergences — v26.10.21 (pointer)

Canonical KD register: [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md)
(rows KD-01..KD-170 — ids non-contiguous — as of 2026-10-22; the
table is ground truth; open/closed status lives in that file's table). Mint
from KD-171 (highest minted id is KD-170; KD-166 Web PubSub handshake by
the AZ-5 lane, KD-167 MHSM release-policy face by the AZ-4 lane, KD-168 MAA
measurement cross-binding by the AZ-2 lane; the Confidential Ledger row
below was originally mis-minted here as KD-166 and renumbered KD-170 in the
BK-139r dual-claim fold). This doc
REGISTERS; it does not
close. Row status mirrors the canonical register; flips only via
`scripts/kd_flip.py --apply`, gated on a PASS witness receipt postdating the
shim mtime. Do not mint new GAP tokens unilaterally.

## Rows minted this window

- KD-161 — OTP 29 removes `statistics(:scheduler_utilization)` —
  CLOSED-OBSOLETE (smalt has no call site; `scheduler_wall_time` deltas are
  the substitute, already in use). Evidence:
  `receipts/bk52-kd161-163-mint.md`, `receipts/ja9-scaling-envelope.md`.
- KD-162 — `:msacc`/`runtime_tools.app` unloadable on the local OTP 29.1.2
  install — ENVIRONMENT-PINION (install fix named; no smalt dependency).
  Evidence: `receipts/bk52-kd161-163-mint.md`.
- KD-163 — blob PUT requires `x-ms-version` (400 MissingXMsVersion) —
  CLOSED-WITH-EVIDENCE as duplicate coverage of KD-136's
  Azure-exact contract (minted-as-reference; second face: blob PUT). Evidence:
  `receipts/bk52-kd161-163-mint.md`, `receipts/ja9-scaling-envelope.md`.
- KD-164 — affidavit wasm seal CTRT invariant gate — host caller
  (`run_seal/5`) never wrote the delta bytes into the guest block, so every
  seal refused deterministically — CLOSED-WITH-EVIDENCE (caller-bug fix;
  court + non-vacuity shim court). Evidence:
  `../v26.10.22/receipts/bk85-seal-invariant.md` (BK-85; minted in the
  canonical register by BK-85).
- KD-165 — workspace sync engine client P12 verify vs the server's
  cumulative per-client receipt chain (verified:false on any flush after
  the first) — CLOSED-WITH-EVIDENCE (client-side full-ledger cumulative
  verify landed; sync-e2e-court 9/9 ×2). Evidence:
  `../v26.10.22/receipts/bk106-sync-engine-fixes.md` (BK-106; minted in the
  canonical register by BK-106).

All five minted 2026-10-21 (KD-161..163 by the kd-registrar lane from the
JA-9 scaling-envelope receipt — no shim obligation; KD-164 by BK-85's
seal-invariant lane, superseding BK-86's no-fold hold; KD-165 by BK-106's
sync-engine-fixes lane from the BK-83 witness).

- KD-170 — Azure Confidential Ledger REST face over the journal substrate
  (AZ-3, 2026-10-21; RENUMBERED from KD-166 in the BK-139r dual-claim fold,
  2026-10-22 — KD-166 is the Web PubSub WS handshake row in the canonical
  register; KD-169 is the Web PubSub server-face row): the receipt `proof`
  is a **full-witness sha256-chain
  fold** over the segment's leaves (`Smalt.Sync.Receipt` algebra), not a CCF
  sparse Merkle-tree proof; `cryptosuite` is the classical
  `smalt-rs256-jws` (no registered W3C Data-Integrity suite); the face is
  served on a dedicated port (8443 `/app/*` remains the pre-existing
  ETS-ledger face — CosmosRoutes owns `POST /app/transactions` there).
  KD-COVERS shim: `lib/smalt/confidential_ledger/{service,router}.ex`
  (`# KD-COVERS: KD-170`). Close condition: a CCF-format receipt verifier
  (sparse multipath proof + node-id chain) verifies the face's receipt
  output, or the face is re-anchored to a registered DI cryptosuite.
  Status: CLOSED-WITH-EVIDENCE (mirrors the canonical register KD-170 row).
  Evidence: receipt
  `../v26.10.22/receipts/az3-confidential-ledger.md` (court transcript).
