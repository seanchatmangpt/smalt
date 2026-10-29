# BK-CERT — certify-tick adversarial audit (confidential_ledger integrity loop)

- **Date**: 2026-10-22
- **Lane**: BK-CERT (read-only skeptic audit; only this receipt written)
- **Repo**: /Users/sac/smalt @ main
- **Standing**: ALIVE
- **Context**: solo

## Scope

The least-audited face of the confidential_ledger surface after the three
repair waves (EXPL11-R1 range guard, EXPL11-R3 seg_meta hardening
[`F5` block in `lib/smalt/confidential_ledger/service.ex:292-344`; note: no
`expl11r3-planes-meta.md` receipt file exists — the hardening is receipted in
`expl11r-repairs.md`], BK-SEAL2 full-green recheck): the certify tick
(`run_certify/1` → `certify_segment/2` → `refuse_segment/4` +
the per-read `reverify_segment/2` law) in
`lib/smalt/confidential_ledger/service.ex`.

## Question

A tampered receipt/segment inside a valid range boundary — the new range
guard passes it by design — does the certify tick fail closed, and does one
bad segment poison the whole tick or degrade per the SPOF-A1 law?

## Probe (real files, real sink, bounded Task, no mocks)

Standalone `mix run --no-start` probe (`/tmp/bkcert_probe.exs`): real
`JournalSink` + real `ConfidentialLedger.Service` on real disk, 3 txs sealed
into 3 separate sealed segments, then a real 1-byte flip in the sealed
segment bytes (`byte 52 of 54`, CRC/manifest-covered region), plus a
fabricated corrupt-meta segment dropped into `sealed/`. Every certify pass
run inside `Task.await(..., 10_000)` (bounded).

Embedded probe output (fresh run):

```
BASELINE: all committed in 3 separate segments
BASELINE receipt ok root=d24fb1264537c55f12a19efee98d40cf030281255fbcf168a6f5353096cd42c9
SEALED=["seg-00000000000000000000.journal", "seg-00000000000000000001.journal", "seg-00000000000000000002.journal"]
TAMPERED seg-00000000000000000000.journal bytes 54 -> 54
LEG1 tick returned :ok in 2.119ms pid_alive=true
LEG1 tampered tx -> {:error, {:integrity, {:segment, "seg-00000000000000000000.journal", {:manifest_mismatch, [...]}}}}
LEG1 tampered receipt -> {:error, {:integrity, {:segment, "seg-00000000000000000000.journal", {:manifest_mismatch, [...]}}}}
LEG1 healthy tx -> "Committed" receipt=:ok
LEG1 service pid unchanged=true
LEG2 tick with corrupt-meta segment returned :ok in 3.951ms alive=true
LEG2 healthy still Committed=true
LEG3 range-covering-tampered -> {:error, {:integrity, {:segment, ... {:manifest_mismatch, ...}}}}
LEG3 range-excluding-tampered -> :ok n=1
LEG3 unbounded-range -> :error
FINAL alive=true whereis_unchanged=true
```

## Verdict

**ALIVE.** The certify tick is crash-safe and fail-closed under the probed
shapes:

- **LEG 1 — tampered committed segment inside a valid range**: the tick
  completes (2.1 ms, bounded Task, `:certify` returns `:ok`), the GenServer
  pid is unchanged (no crash/restart), `transaction/1` AND `receipt/1` both
  return the typed `{:error, {:integrity, {:segment, name,
  {:manifest_mismatch, [path:, expected_sha256:]}}}}` — fail-closed per read
  (SJ-2), never a stale pass. The healthy segments' tx and receipt still
  verify `Committed`/`:ok` on the SAME tick — per-segment degradation, no
  whole-tick poisoning.
- **LEG 2 — never-certified segment with corrupt meta**: typed refusal
  (`refuse_segment/4` → `:corrupt_meta` via the EXPL11-R3 `seg_meta/1`
  hardening); tick completes, healthy segments stay committed, no crash.
  Discovery-level structural incompleteness (no `.seal`/meta) is quarantined
  upstream by the SPOF-1 reader law, so `certify_segment/2` only sees
  complete triples here — consistent with the layered design.
- **LEG 3 — valid range boundary vs tampered content**: a valid range
  covering the tampered tx refuses typed; a range excluding it serves the
  healthy page (`:ok`, n=1). The EXPL11-R1 guard correctly refuses only
  malformed ranges; tamper is handled by the integrity layer, not the range
  guard — the guard passing tamper through is by-design layering, correct.

## Findings (typed)

1. **BK-CERT-F1 (low, fail-closed-direction, no repair required)**: at the
   `transactions/3` listing level, ONE bad segment poisons the WHOLE page —
   `transactions(nil, nil)` returns `{:error, {:integrity, ...}}` for the
   entire listing even though the healthy txs' page members verify fine
   (LEG 3 unbounded-range arm). This is typed and fail-closed (never a
   silent pass), consistent with SJ-2, but coarser than the SPOF-A1
   per-segment degradation the tick itself exhibits. Repair ticket (if ever
   filed): per-tx integrity degradation in listings — keep healthy entries,
   mark the tampered tx as an integrity-refused row, never a silent pass —
   or at minimum include the failing segment name in the error body surfaced
   by `GET /app/transactions` router arm. Not filed as a KD row: the
   divergence direction is safe (refuse-typed), not a wire divergence.
   Left as-is per ERRC asymmetry (refuse-typed already outranks a nicer
   shape); the tick face itself (this lane's subject) degrades per-segment.
2. **BK-CERT-F2 (doc drift, informational)**: the task briefing named
   `expl11r3-planes-meta.md` as a receipt; no such file exists in
   `docs/jira/v26.10.22/receipts/`. The seg_meta hardening (EXPL-11 F5) is
   receipted in `expl11r-repairs.md` and carried the `# KD-COVERS`-style
   comment block at `service.ex:295-300`. No action beyond this note.

## Regression (fresh, this lane)

```
$ MIX_BUILD_ROOT=_build-bkcert mix test \
    test/integration/az3_confidential_ledger_court_test.exs \
    test/integration/az3b_ledger_mount_court_test.exs \
    test/internal/expl11r1_ledger_range_court_test.exs \
    test/internal/expl11r3_court_test.exs
Result: 20 passed, exit 0
```

## Replay

```
MIX_BUILD_ROOT=_build-bkcert mix run --no-start /tmp/bkcert_probe.exs   # probe (scratch, /tmp)
MIX_BUILD_ROOT=_build-bkcert mix test test/integration/az3_confidential_ledger_court_test.exs \
  test/integration/az3b_ledger_mount_court_test.exs \
  test/internal/expl11r1_ledger_range_court_test.exs \
  test/internal/expl11r3_court_test.exs
```

## Lane bounds

Read-only on `lib/` and `test/`; only this receipt file written in-tree.
`/tmp/bkcert_probe.exs` is scratch. No `_build-bkcert` committed; lane build
root is leased for this receipt only.
