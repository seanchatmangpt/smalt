# PLANNING.md — v26.10.20 window seed

- **Date**: 2026-10-19 (window open)
- **Source**: `docs/jira/v26.10.19/FINAL.md` §7 (planning handoff) + the
  KD-114..119 mint batch (registrar-gated; the register currently ends at
  KD-113, mint contiguous, never renumber — KD-113 registrar ruling).
- **Base at planning time**: HEAD `81a7a29` (main, 22 commits ahead of
  origin/main; version 26.10.18).
- **Context**: solo(planning lane; docs-only)

## Standing carried from v26.10.19

- court-x2 close receipt
  `docs/jira/v26.10.19/receipts/v261019-12-court-x2-close.md` records
  Standing **NOT-RUN**; G5 (dual-pass receipt) is typed-PENDING. The
  receipt pins base `64f6099` — a landing pair in this window must re-pin
  at its own landing SHA, disclosed in the close receipt.
- publish-dry: NOT RUN in v26.10.19; carried as a wrap obligation here.
- G2 (F1 revert-the-diff acceptance gate) is typed-DEFERRED on TS-suite
  green; the F1 coverage-falsifier court is landed and fail-closed but
  typed-SKIPs until the external TS suite is green.

## WO table

| # | Name | Priority | Depends on | Close condition (receipt-gated) |
|---|---|---|---|---|
| WO-1 | **TS-suite green push** — 6 honest emulator divergences, each a sub-sketch with falsifier (see below) | **P0** | — | `cd verification/ts && node run.mjs` exit 0, green x2 at one pinned SHA; each fixed divergence witnesses green in the suite leg that was red |
| WO-2 | F1 falsifier unblock (BEFORE gate currently typed-SKIP) | **P0** | WO-1 | F1 revert-the-diff court exits 1 on the reverted subject and 0 on the landed diff; G2 flips DEFERRED→PASS with receipt |
| WO-3 | cosmos.ex accessor bypass fix (`cosmos_ru_limit`, `:heir`/accessor family — sibling of arm c41e8ae) | P1 | — | ru-limit transient state rides the `:heir`/accessor pattern; falsifier test kills the owner and observes the value survives (or the request retypes); `mix test` green at the pinned SHA |
| WO-4 | Secrets-sweep + envelope courts | P1 | — | sweep + envelope courts exit 0 clean and exit 1 on their shim fixtures (AFTER-legs flip; non-vacuity per shim-court law) |
| WO-5 | court-x2 completion → release receipt; then `just publish-dry` | **P0** (final gate) | WO-1, WO-3, WO-4 landed | `just quiet-check` exit 0 then `just court-x2` exit 0 on BOTH legs at one pinned SHA; release receipt minted; `just publish-dry` exit 0; G5 typed-PENDING→closed receipt-gated |
| WO-6 | **Carried** v26.10.19 WO-2 — SOVEREIGN_MIDNIGHT G-register (G2 X-ARR mTLS, G3 EG DLQ spillover, G4 split-brain failover) | P1 | G4 behind G2/G3 | unchanged from `docs/jira/v26.10.19/WORK_ORDERS.md` (row flips receipt-gated in SOVEREIGN_MIDNIGHT.md) |
| WO-7 | **Carried** v26.10.19 WO-5 — isolation runtime5 quiet-window rerun (`just quiesce` / `quiet-check` discipline) | P1 | quiet window | `python3 scripts/isolation_court.py --runtime-only` counts 0; register row flips with receipt |

## WO-1 sub-sketches — the 6 wire divergences (KD-114..119 mint batch)

Each sub-sketch: proposed fix + falsifier. Registrar-gated: mint
contiguous KD-114..119 rows via the kd-registrar lane only, each row
citing its witness receipt; flips via `scripts/kd_flip.py --apply`
receipt-gated.

| Sub | Divergence (witness) | Proposed fix | Falsifier (must flip the suite leg) |
|---|---|---|---|
| WO-1a | Blob bearer-only egress — no TLS blob channel on 9444 | Route the blob data-plane channel through egress TLS dispatch (same twin discipline the SDK legs already ride) | `@azure/storage-blob` over the TLS twin: container create/put/get green where it now fails on the bearer-over-http refusal |
| WO-1b | SB receiver zero-delivery on flow credit | Investigate the receiver link flow/credit path — deliveries are credited but never written to the wire | `@azure/service-bus` receiver observes ≥1 delivery within a bounded poll after sender closes; zero-delivery red flips green |
| WO-1c | Session deliveries without settle methods | Envelope the settle-method surface (complete/abandon/dead-letter) on session receivers | session receiver completes a message; the settlement is observed on a re-receive (locked-until clears), not asserted by call-count |
| WO-1d | KV deleted-keys plane 404s (soft-delete witness landed; plane incomplete) | Complete the deleted-keys plane with the `:heir` pattern (request-transient ETS, owner + heir) | list/get on a deleted key returns the soft-delete face (recovery window fields), 404 only past purge |
| WO-1e | scheduleMessage 501 UNSUPPORTED (typed) | Either implement the op or mint the typed-UNSUPPORTED face with a KD row — never a bare 501 | SDK sees a typed UNSUPPORTED face (or a working schedule op); leg records the registered divergence, not a raw 501 |
| WO-1f | Vault sign single-hash divergence | Fix the sign surface to the single-hash digest contract the SDK sends | `@azure/keyvault-keys` sign leg verifies a signature over the digest it submitted (Node `crypto.verify` roundtrip) |

## Dependency order

```
WO-1 (TS green, sub-sketches a–f) ──→ WO-2 (F1 unblock) ──┐
WO-3 ∥ WO-4 (independent lanes) ──────────────────────────┼──→ WO-5 (court-x2 → publish-dry → release receipt)
WO-6 ∥ WO-7 (carried, independent) ───────────────────────┘
```

WO-5 is the terminal gate: nothing lands after its pinned-SHA pair.
KD-114..119 minting rides WO-1's witness receipts (registrar lane).

## Shared-file seams (preview — full _LANES.md at materialization)

| File | Owner(s) |
|---|---|
| egress TLS dispatch / blob twin channel | WO-1a |
| `lib/smalt/messaging/` SB receiver flow + settle envelope | WO-1b / WO-1c (disjoint: flow credit vs settle methods) |
| `lib/smalt/data_plane/keyvault*.ex` deleted-keys | WO-1d |
| scheduleMessage arm | WO-1e |
| vault sign surface | WO-1f |
| `lib/smalt/data_plane/cosmos.ex` (accessor bypass ~line 1841) | WO-3 |
| KD-114..119 rows | kd-registrar lane only |
| generated docs (RECEIPTS/SDK_MATRIX/BENCH/ERROR_CODES) + FINAL.md | wrap lane exclusive |

## Constraints carried

- Non-duplication / portable-target / sleep-gate gates cover
  `verification/{ts,py}` and `test/internal` — every close condition that
  touches those trees re-runs them.
- Receipt-context law: every witness receipt carries
  `Context: solo|pair|slice|full`; `just quiet-check` before any court.
- No GAP tokens minted unilaterally; KD flips only via
  `scripts/kd_flip.py --apply`, receipt-gated.
- Lane builds `MIX_BUILD_ROOT=_build-lane<N>`; no stash; commits
  `git commit -F <file>`.
