# Receipt: fin34 — session knowledge-ledger close

- repo: /Users/sac/smalt @ main (518b31a working tree)
- lane: fin34
- date: 2026-10-16

## Scope

Close the session's knowledge ledger: poll for fin33, verify standing rules + memory
against the session's durable knowledge, add only what is missing (max 3), sweep stray
scratch.

## Poll

fin33 not present at lane start (~21:0x); landed during the lane as
`fin33-planning-summary.md` (witnessed by ls after ~4 min of polling). Not read or
validated by this lane — fin33's own receipt stands.

## Verified already there (no edit)

- b) justfile import-module variable-prefix rule (per-module prefixed variable names,
  bare `ROOT :=` collision) — already in `~/.claude/rules/same-checkout-fanout.md`
  addition 5 (2026-10-16 v26.10.14 wave block). Not duplicated.
- Port ranges (ARM 9443 + TLS twin 9444, egress 8443, AMQP 5672, census 39790+,
  `SMALT_TEST_*_PORT`) — already in memory `smalt-substrate-ops.md`. Not duplicated.
- court-x2 / publish-dry recipe names — already in memory
  `smalt-release-wrap-sequence.md`. Not duplicated.
- SDK-parity register (KD rows, coverage compiler, test-premises-rot law) — already in
  `~/.claude/rules/testing-chicago-style.md`. Not duplicated.

## Added (3)

1. **Shim-court protocol as a named pattern** → `~/.claude/rules/testing-chicago-style.md`
   SDK-parity section: BASELINE(sha256) → BEFORE → SHIM(`SHIM-COURT` marker) → AFTER →
   RESTORE(sha256 fail-closed); non-flipping court = FAIL, loud typed `[SKIP]`, real
   self-check corruption of a temp-copy restore proves non-vacuity. Canonical:
   smalt `scripts/shim_court/lib.sh`, `just shim-court(s)`.
2. **KD-COVERS/SIM-PASS auto-flip, one line** → same section: flip to CLOSED-SIMULATED
   only when a PASS witness receipt postdates the shim's mtime; all-simulated coverage
   cells render SIM-PASS, not native PASS.
   Canonical: `scripts/kd_flip.py`, receipts `s6-shim-court-harness.md`, `s7-kd-flip.md`.
3. **verify-all recipe reference** → memory `smalt-substrate-ops.md`: wave recipes ride
   the same substrate (`just verify-all` full ladder; court-x2/publish-dry via
   [[smalt-release-wrap-sequence]]).

## Scratch sweep

- Removed stale /tmp lane residue: `/tmp/amqp_framing_court_conn_shimmed.ex`,
  `/tmp/s1-amqp-shim-court_conn_shimmed.ex`, `/tmp/s1-amqp-shim-court_substrate.log`
  (Oct 15 court scratch; no running shim-court process at deletion — pgrep clean).
- Substrate locks (`/tmp/smalt-substrate*.lock`, state files) left in place — live
  leases, not receipts.
- `docs/jira/v26.10.14/receipts/` listing checked: all files receipt-named .md, no
  misfiles found.

## Sources read for verification

`~/.claude/rules/same-checkout-fanout.md` (additions 1-6), `~/.claude/rules/testing-chicago-style.md`,
memory/{MEMORY.md, smalt-release-wrap-sequence.md, smalt-substrate-ops.md},
receipts `s6-shim-court-harness.md`, `s7-kd-flip.md`, `s8-wave-telemetry.md`.
