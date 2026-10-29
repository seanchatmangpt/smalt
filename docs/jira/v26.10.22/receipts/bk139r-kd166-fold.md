# BK-139r — KD-166 dual-claim fold (Confidential Ledger renumber)

**Standing: ALIVE** — the dual-claim is folded: the Confidential Ledger row
is minted as **KD-170** in the canonical register (CLOSED-WITH-EVIDENCE,
evidence `receipts/az3-confidential-ledger.md`), both `# KD-COVERS` markers
renumbered, both pointers bumped. `scripts/kd_flip.py` read-only exit 0 with
KD-170 resolved against the register; `just docs-dod-check` exit 0.
**Context**: solo
**Date**: 2026-10-22
**Repo**: /Users/sac/smalt @ main, uncommitted (per task law).

## Before

- `lib/smalt/confidential_ledger/{service,router}.ex` carried
  `# KD-COVERS: KD-166` — colliding with the canonical register's KD-166
  (Web PubSub WS handshake, lib/smalt/webpubsub/*).
- No Confidential Ledger row existed in the canonical register
  (docs/jira/v26.10.14/KNOWN_DIVERGENCES.md); the row lived only in the
  v26.10.21 pointer, mis-minted as KD-166.
- v26.10.22 pointer header: "Mint from KD-170 (highest minted id is
  KD-169)" — i.e. **KD-169 was already taken** (Web PubSub server-face row,
  EXPL-4 F5), so the relaunch instruction's guess "mint KD-169" was stale;
  the register-verified next-mint is **KD-170**.

## After (files owned by this lane)

1. `lib/smalt/confidential_ledger/service.ex` — marker now
   `# KD-COVERS: KD-170 (Confidential Ledger receipt face; renumbered from
   KD-166 — dual-claim fold, KD-166 is the Web PubSub WS handshake row)`.
2. `lib/smalt/confidential_ledger/router.ex` — marker now
   `KD-COVERS: KD-170 (the receipt proof is a full-witness sha256-chain ...`.
3. Canonical register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) — KD-170
   row appended after KD-168 (surface: Confidential Ledger receipt proof
   algebra, service.ex chain-map_reduce + router.ex; divergence: full-witness
   sha256-chain fold, not a CCF sparse Merkle proof; classical
   `smalt-rs256-jws`, no registered DI cryptosuite; dedicated port).
   Status **CLOSED-WITH-EVIDENCE**, evidence
   `docs/jira/v26.10.22/receipts/az3-confidential-ledger.md` (AZ-3 court 6/6
   green: append 5 → poll Committed → receipts verify vs recomputed chain;
   tamper typed-refuses; crash-window Pending; degraded 503 no-tx; VC
   round-trip; range+pagination). Fold provenance noted in-row.
4. v26.10.21 pointer — row retitled KD-166 → KD-170 with RENUMBERED note,
   KD-COVERS ref → KD-170, status mirrors canonical
   (CLOSED-WITH-EVIDENCE); header bumped: rows KD-01..KD-170, Mint from
   KD-171, mis-mint note recorded.
5. v26.10.22 pointer — header bumped (Mint from KD-171, highest minted
   KD-170); KD-170 row minted (CLOSED-WITH-EVIDENCE, same evidence receipt).

## Gates (real output)

- `python3 scripts/kd_flip.py` → **exit 0**. Covers-map 115 ids / 138 files;
  `KD-170: [CLOSED-WITH-EVIDENCE] lib/smalt/confidential_ledger/service.ex`
  resolved against the register (no unknown-id exit-1, i.e. zero
  register-skew for this fold). Pre-existing (not this lane's): KD-168 is
  FLIP-ELIGIBLE but still OPEN in the register (AZ-2 owner's receipt-gated
  flip, per az2-maa-attestation.md); KD-166 remains OPEN over the webpubsub
  shims — correct, that is the WS-handshake row.
- `just docs-dod-check` → **exit 0** (all 65 paths OK).

## Verification notes

- Both edited .ex files parse: standalone `elixirc` tokenizes both; the only
  error is `use Plug.Router` macro expansion (deps not on the standalone
  path) — expected outside `mix compile`.
- Full `mix compile` (MIX_BUILD_ROOT=_build-bk139r) currently exits 1 on
  `lib/smalt/storage/journal_sink.ex:621 missing closing delimiter` —
  **pre-existing**, an uncommitted 75-line in-flight diff from another lane
  (scopes feature), present on the tree before this lane's edits; this lane
  owns no line of it (disclosed per compile-freeze SLA). Not repaired here —
  not lane-owned.

## Falsifier

`grep -n "KD-COVERS: KD-166" lib/smalt/confidential_ledger/` non-empty, or
KD-170 absent from `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, or
`scripts/kd_flip.py` exit 1.
