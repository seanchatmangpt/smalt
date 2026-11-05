# R4-I — rows-carrier through the cgap Arrow IPC surface

Standing: PARTIAL_ALIVE

Date: 2026-11-04/05 · Repos: /Users/sac/cgap + /Users/sac/smalt · Lane R4-I
(repositioning wave). Backfilled receipt: this lane's original receipt never
landed on disk (its content rode in the lane's final message); this file is
reconstructed from the drift-census facts so the both-receipt law has a
counterparty on disk.

## Landed diff (all on disk, gates green)

- `crates/cgap-arrow/src/ipc.rs` — landed inside L7's leased file:
  `KEY_ROWS` const added; `emit_fb_inner` gains a rows param; ancillary
  3-tuple extension; `FbRead.rows` field + `RowsCarrierMissing` typed
  refusal.
- `crates/journal-export/` — dual-era fork of the walker (old-era vs
  rows-carrying frames).
- smalt side — mount fb walker updated + shared fixture, both repos.

## Coordination

- Guard F4 (coordination guard): PASS.

## Gates (real runs)

- cgap-arrow suite: 29/29.
- journal-export suite: 5/5.
- smalt mount/fb walker: 15/15.

## Cross-lane disclosure

- R4-I's rows-carrier edits landed inside L7's leased
  `crates/cgap-arrow/src/ipc.rs` + `crates/cgap-arrow/tests/ipc_courts.rs`
  (KEY_ROWS / emit_verified_fb_rows / F-section overlap). No L7 receipt
  exists on disk under `smalt docs/jira/v26.11.6/receipts/` or
  `cgap docs/jira/v26.11.6/lanes/` (closest on-disk mention:
  `lane-hr-i-port-law.md` "cloned from _build-lane7"), so this receipt
  carries the counterparty disclosure for the merged tree: merged tree
  green, disclosed both-receipts. A landing coordinator owning L7's
  receipt should mirror this line into it.
