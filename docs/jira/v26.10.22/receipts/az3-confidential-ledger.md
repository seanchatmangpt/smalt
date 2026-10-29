# AZ-3 — Azure Confidential Ledger REST face over the journal substrate

**Standing: PARTIAL_ALIVE — court 6/6 green on the real HTTP face (append 5
→ poll Committed → receipts verify against the recomputed chain; tamper
typed-refuses; crash-window stays Pending; degraded sink 503s with no tx
recorded; VC certificate round-trips; range + pagination). KD-166
registered. Residue: production supervision mount (supervisor child +
pinned port) not wired — the face is mounted by the court and by any
caller via `Bandit.start_link(plug: Smalt.ConfidentialLedger.Router, ...)`.**
**Context**: solo
**Date**: 2026-10-21/22
**Lane**: AZ-3 (Tier 1), per BK-117's "architecturally realized but
protocol-less" finding — the cheapest high-value win.
**Repo**: /Users/sac/smalt @ main (uncommitted worktree;
MIX_BUILD_ROOT=_build-az3). Not committed per task law.

## Mapping table (ACL face → landed substrate)

| ACL concept       | Landed substrate |
|---|---|
| `POST /app/transactions` `{"contents"}` → `201 {"transactionId":"N.1"}` | one `Smalt.Storage.JournalSink.append/6` frame (payload = JSON contents) |
| PENDING → Committed | frame in open segment → Pending; **certification = `maybe_seal` through the real SJ-1 seal ladder + SJ-2 fail-closed re-read + sequential sha256-chain fold** (`Smalt.Sync.Receipt.absorb/2`) |
| `GET .../receipt` `{leaf, root, proof}` | 320-byte `Smalt.Sync.Receipt.mint/1` token exposed as ACL JSON; `proof` = full-witness leaves; **root re-verified fail-closed per read** (tampered segment → typed refusal, SJ-2 law) |
| `GET .../certificate` | `Smalt.Receipt.VcExport.to_vc/2` (VC 2.0, `smalt-rs256-jws`) over the same token |
| range listing + `nextRangeLink` | per-service tx map ordered by SeqID |
| transactionId `"<seq>.1"` | the sink's monotonic SeqID |
| degraded ledger | A-1 law: sink `:degraded` → `503 LedgerDegraded`, **no tx recorded** (accepted-and-dropped never reads as an admission) |
| crash-window (BK-54/SPOF-A3) | sentinel withheld → discovery quarantines the segment → tx stays **Pending**, receipt `409 TransactionNotCertified` — never silently committed |

## Files (lane-owned)

- `lib/smalt/confidential_ledger/service.ex` (new) — `Smalt.ConfidentialLedger.Service`
- `lib/smalt/confidential_ledger/router.ex` (new) — `Smalt.ConfidentialLedger.Router` (`# KD-COVERS: KD-166` in both)
- `test/integration/az3_confidential_ledger_court_test.exs` (new) — the court
- `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` — KD-166 row appended
- compile-freeze SLA unblock (disclosed, another lane's file):
  `lib/smalt/messaging/kafka/records.ex` — two @spec type refs
  `record()` → `kafka_record()` (the tick sweep committed a mid-rename
  state that type-spec-refused; tree was unbuildable ~15 min). Minimal,
  typed-equivalent fix; owning lane may re-pin.

## Court (real HTTP, real disk, real chain; no mocks)

Legs (all over a real Bandit listener + curl, real `JournalSink` on disk,
real Service certification):

1. **ACL face end-to-end** — POST 5 (`201 {"transactionId":"N.1"}`), poll
   each to state Committed (bounded audited poll, 40ms certify tick), GET
   each receipt: `leaf` == recomputed leaf of the tx's frame from the
   on-disk sealed segment, `root` == chain root recomputed independently
   from the on-disk frames, proof refold == root,
   `receiptToken` == `Receipt.mint` over the recomputed chain. Range query
   `rangeBegin=2.1&rangeEnd=4.1` → exactly `2.1,3.1,4.1`,
   `nextRangeLink` null; service-level pagination (limit 2 → page1 of 2 +
   nextRangeLink → page2 non-empty).
2. **Tamper** — flip one byte in the sealed segment on disk → receipt AND
   state endpoints both `409 LedgerIntegrityFailure` (fail-closed per
   read, never a stale pass).
3. **Crash (BK-54/SPOF-A3 class)** — append 1, seal via the real ladder,
   withhold the `.seal` sentinel, force a certification pass → discovery
   quarantines the segment (quarantine/ non-empty, bytes preserved), tx
   stays `Pending`, receipt `409 TransactionNotCertified` — never silently
   committed.
4. **Degraded sink** — real disk-error injection (regular file where
   `active/` must be a dir, injected before the fresh sink boots) → POST
   → `503 LedgerDegraded`, service records no transaction.
5. **Certificate** — VC 2.0 structure pinned (@context v2 base in list,
   `MerkleReceiptCredential` type, `smalt-rs256-jws` cryptosuite),
   `VcExport.verify_vc/1` round-trip `{:ok, _}`.
6. **404** unknown transactionId.

## Court transcript (final quiet-window green run)

```
$ export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
$ MIX_BUILD_ROOT=_build-az3 mix test test/integration/az3_confidential_ledger_court_test.exs
Finished in 0.6 seconds (0.00s async, 0.6s sync)
Result: 6 passed          (exit 0; /tmp/az3-q5.log; 0 compilation errors)
```

Stability: first green run 6/6, then repeat runs blocked ONLY by other
lanes' in-flight compile breaks (egress_router.ex mismatched-delimiter,
kql.ex, webpubsub/token.ex — transient, none in this lane's files; each
self-healed when the owning lane saved its file). The quiet-window rerun
loop converged green (run 5): the court is deterministic in a quiet
window; the interleaved failures were all `== Compilation error` in
other-lane files, never a court assertion failure after the fold fix.

## KD-166 (registered, OPEN)

docs/jira/v26.10.21/KNOWN_DIVERGENCES.md — the receipt `proof` is a
full-witness sha256-chain fold (not a CCF sparse Merkle proof);
`smalt-rs256-jws` is not a registered W3C DI cryptosuite; face served on
a dedicated port (8443 `/app/*` remains the ETS-ledger face). KD-COVERS
shims: the two lib files carry `# KD-COVERS: KD-166` (moduledoc pin).

## Falsifier status

- Court leg 2 (tamper) is the non-vacuity face of the integrity gate:
  pre-gate behavior would 200 the receipt from the in-memory
  certification record; the gate re-reads the sealed bytes and refuses.
- Leg 3 is the non-vacuity face of the completeness law: the quarantined
  segment's tx never flips to Committed (court asserts the Pending state
  and the typed receipt refusal on the wire).
- Leg 4 is the non-vacuity face of the A-1 law: the degraded sink's
  accepted-and-dropped append never becomes a recorded tx (no silent
  admission).

## Residuals

- Production supervision mount (application.ex child + pinned port) is
  out of this lane (shared file, coordinator-owned); the face is fully
  mounted per-test by the court and can be mounted by any caller.
- The `latest` endpoint rides `Service.transactions(nil, nil, 1_000_000)`
  — O(n) per call; fine at emulator scale, bounded at the router.
- Another lane's AZ-4 unblock edit (map_reduce fold rewrite disclosed in
  the service file) was superseded by this lane's `Enum.reduce` fix; the
  "compile-freeze SLA unblock fix, AZ-4 lane" comment in the file is
  stale and owner may clean it.

## Addendum — 2026-10-22 (AZ-3b mount landed; residue closed)

The production supervision mount landed and the mount court is green ×2:

- Wiring: `lib/smalt/plane/data_supervisor.ex` (data-plane tree) starts
  `{Smalt.ConfidentialLedger.Supervisor, []}`; the supervisor mounts
  `Smalt.ConfidentialLedger.Sink` (dedicated `JournalSink`,
  `:acl_journal_dir`, default `var/acl-journal`) →
  `Smalt.ConfidentialLedger.Service` → `Bandit` (`Smalt.ConfidentialLedger.Router`,
  `:confidential_ledger_port`, default 8444, loopback bind law).
- Fixes this session (owner files): explicit `id:` on the Sink and Bandit
  child_specs in `lib/smalt/confidential_ledger/supervisor.ex` — the
  child ids previously defaulted to the module names
  (`Smalt.Storage.JournalSink`, a Bandit `#Reference<>`), so the mount
  court's shape assertion (children present under their documented
  names) could not pass.
- Court: `MIX_BUILD_ROOT=_build-bk143 asdf exec mix test
  test/integration/az3b_ledger_mount_court_test.exs` →
  `Result: 2 passed` twice (run 1 + run 2, 2026-10-22, asdf-pinned).

Compile-freeze SLA disclosure: the shared tree was mid-edit from other
lanes (egress_router.ex delimiter churn, webpubsub/token.ex Joken.Claim
KeyError, data_plane/kql.ex bin_value). No unblock edits to those files
were made by this lane — each lane repaired its own file within the SLA
window (bounded poll confirmed tree-compiles at 00:44:45 before the
court runs). Residual "out of this lane (shared file)" note above is
superseded.

Standing: PARTIAL_ALIVE → the ACL REST face mount is ALIVE (court-witnessed
×2 on the live supervision tree); remaining PARTIAL scope is the receipt's
own residuals (O(n) `latest`, stale AZ-4 comment), not the mount.
