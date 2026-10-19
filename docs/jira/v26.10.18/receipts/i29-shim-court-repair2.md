# Receipt: i29 shim-court repair2 (2026-10-19)

- Standing: PASS (3/3 previously-FAIL courts flip; restores byte-exact)
Context: pair(shim-court-repair2 lane + skeptic re-read of court/witness/lib
  sources before each verdict; no mocks — real substrate for etag_cas, real
  ExUnit run for tombstone_grace, real Plug conn through EgressRouter for
  comp_whitelist)
- Subject: `scripts/shim_court/{comp_whitelist,etag_cas,tombstone_grace}_court.sh`
  and their subjects, repo /Users/sac/smalt
- Baseline: `docs/jira/v26.10.18/receipts/i29-shim-court-verify.md` (3 FAIL:AFTER)
- Law honored: no flip weakened. comp_whitelist + tombstone_grace needed NO edit
  (premise rot already repaired by the 2026-10-18 lane — see verdicts below).
  etag_cas was a SHIM defect, not an AFTER re-anchor: the shim now removes MORE
  protection (the ConditionalHeaders guard plus the CAS), never less.

## Verdicts (this session, real runs)

| court | verdict | flip receipt |
|---|---|---|
| comp_whitelist | PASS | AFTER witness: "all 10 unimplemented PUT comps -> typed 400; GET comps refused; body unchanged"; BEFORE: "corruption witnessed — comp=lease overwrote blob body"; restore sha256-verified |
| tombstone_grace | PASS | BEFORE: 5 tests, 0 failures; AFTER: `sweeper_test.exs:50` failed BY NAME (`assert {:ok, %{locked_until: 1100}} = LockManager.get(lock.lock_token)`), not a compile error; restore sha256-verified |
| etag_cas | PASS (after shim repair, below) | BEFORE: gate verdict PASS (positive 6/6 checks). AFTER: gate rc=1, verdict FAIL, positive FAIL names "exactly one 200 and five 412s (got [200, 200, 200, 200, 200, 200])" — six 200s, lost update, runtime FAIL not a compile/ERROR fake; restore sha256-verified |

## etag_cas: root cause and repair (the only edit this session)

`scripts/shim_court/etag_cas_court.sh` — `apply_shim` widened (marker intact).

Root cause (witnessed, not inferred): the old shim replaced the atomic CAS with
`Store.put` but KEPT `ConditionalHeaders.evaluate(headers, existing["_etag"]) == :proceed`
as the cond branch condition. Over 6 concurrent conditional PUTs the branch
condition re-reads the CURRENT stored record per request; every loser after the
first winner evaluates its (now stale) If-Match against the fresh record and
falls into the `true ->` 412 catch-all. The pristine 1x200 + 5x412 distribution
reproduced WITHOUT any atomicity, so the gate's positive phase still passed
under the shim → the flip was impossible for any AFTER expectation. Verified
live: first run of this session, gate verdict PASS under the old shim
(positive "exactly one 200 and five 412s (got [200, 412, 412, 412, 412, 412])").

Repair: the shim now also neutralizes the guard — the cond branch becomes
`if_match != nil ->` with an unconditional `Store.put`, so every conditional
writer proceeds through a non-atomic check-then-write: six 200s, the lost-update
class the gate must refuse. The gate itself is untouched (it correctly refused
the shimmed runtime and its negative fixtures still refuse).

Diagnosis class: court-script premise rot (shim under-scoped for the current
put_doc design where the branch condition itself re-reads state per request),
NOT a missing lib fix. The landed CAS in `lib/smalt/data_plane/cosmos.ex:778`
is present and load-bearing (BEFORE leg proves it holds under the gate).

comp_whitelist and tombstone_grace: the recorded fixes (router comp whitelist
at `lib/smalt/egress_router.ex:3662`, sweeper tombstone grace call site at
`lib/smalt/messaging/amqp/sweeper.ex:64`) are genuinely landed; the earlier
verify-run FAILs were stale-state from before the 2026-10-18 repair lane. Both
courts pass unmodified.

## Post-run integrity

- `lib/` subjects restored byte-exact (per-court sha256 RESTORE lines above;
  marker greps confirm only pre-existing prose comments remain).
- No git operations.
