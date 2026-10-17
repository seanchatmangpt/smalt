# R211: courts final batch — disposition_token / ets_cleanup / atom_bridge / amqp_framing / settle_cas

Standing: PASS (4 of 5 PASS; disposition_token loud SKIP, see below)
Lane: milestone-doc lane 311 · 2026-10-16
Surface: `scripts/shim_court/{disposition_token,ets_cleanup,atom_bridge,amqp_framing,settle_cas}_court.sh`
Subjects: `lib/smalt/messaging/amqp/connection.ex`, `test/mcp_wire_test.exs` (+ aux `test/mcp_test.exs`, `test/smalt_arm_gateway_test.exs`), `lib/smalt/messaging/amqp/atom_bridge.ex`, `lib/smalt/messaging/amqp/queue_store.ex`

## Claim

The five courts named in the lane assignment re-run green on the current tree, each with a
witnessed BEFORE→SHIM→AFTER flip and byte-exact restore — except `disposition_token`, whose
subject has already landed its flip (loud SKIP, not a fake pass).

## Re-run evidence (all: MIX_BUILD_ROOT=_build-lane311)

### disposition_token — SKIP (exit 3, loud)

```
$ MIX_BUILD_ROOT=_build-lane311 just shim-court disposition_token
[SKIP] disposition_token_court: subject degraded: connection.ex lacks lock_token: dlv.lock_token settle threading (already mutated?)
EXIT=3
```

Not a silent pass: the flip this court guards has ALREADY landed in the subject —
`lib/smalt/messaging/amqp/connection.ex` now carries the settle threading the court's BEFORE
anchor requires absent (`lib/smalt/messaging/amqp/connection.ex` lines 2185/2192/2204:
`case QueueStore.complete/release/deadletter(dlv.queue, dlv.seq, lock_token: dlv.lock_token)`).
The court protocol is pre-landing-only: it cannot install the unthreaded baseline, so per the
skip-is-loud contract it exits 3 rather than faking a pass. Standing for this entry:
PARTIAL_ALIVE (flip landed and visible in the subject; court non-vacuity not re-witnessed on
the landed tree). Close condition: re-anchor the court on the pre-landing baseline (the same
pattern `amqp_framing_court.sh` uses with `scripts/shim_court/amqp_connection_baseline.ex`),
then re-run to PASS.

### ets_cleanup — PASS (exit 0)

```
$ MIX_BUILD_ROOT=_build-lane311 just shim-court ets_cleanup
[SHIM] baseline sha256(test/mcp_wire_test.exs) = bc3a076018b0100cf97e5539d448dcf35871f9ace9bc770d3b1f67217cb86d12
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to test/mcp_wire_test.exs (SHIM-COURT marker present)
[AFTER] flip proven: neutralized on_exit cleanups left seeded rows live; the appended witness failed enumerating them
     ** (RuntimeError) R189 LEAKED KEYS: cleanup disabled left seeded rows live after the suite: [smalt_resources: ".../storageaccounts/mcpacct", smalt_blobs: "mcpacct/mcpcontainer/notes.txt", smalt_vault_keys: "mcp-key"]
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] ets_cleanup_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
[SHIM] RESTORE verified byte-exact on aux subjects test/mcp_test.exs and test/smalt_arm_gateway_test.exs (sha256 match)
EXIT=0
```

### atom_bridge — PASS (exit 0)

```
$ MIX_BUILD_ROOT=_build-lane311 just shim-court atom_bridge
[SHIM] baseline sha256(lib/smalt/messaging/amqp/atom_bridge.ex) = 60d34323451137f72f880cded70f4d2c2c6ee42f31f486e18303cde6680b8077
[BEFORE] PUT /atom-court-1792163084586937875 -> 201, 12-field QueueDescription (LockDuration PT45S parsed) — old signature holds
[SHIM] shim applied to lib/smalt/messaging/amqp/atom_bridge.ex (SHIM-COURT marker present)
[AFTER] PUT /atom-court-1792163090043813458 -> 405 MethodNotAllowed — shim flipped the bridge (non-vacuous)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] atom_bridge_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
EXIT=0
```

### amqp_framing — PASS (exit 0)

```
$ MIX_BUILD_ROOT=_build-lane311 just shim-court amqp_framing
[court] pristine baseline verified sha256=ea5a13708e87ccaf4244a8dce93d2ffd0636cc3c84624db46801ea44e2b651ae
[court] lock held: /tmp/smalt-shim-court-connection.ex.lock (fd 9)
[court] live connection.ex snapshot sha256=42cec4e4f66fd4ed0b4ca704854d1bbd7d4950825a02cf71728c4c01d6c077d4 (restore point)
== BEFORE: running pyamqp witness against UNSHIMMED broker ==
[BEFORE] live leg FAILED as expected (rc=3, signature: WITNESS_TIMEOUT)
== AFTER: restore live connection.ex from live snapshot ==
[court] live restore verified byte-exact
== AFTER: running pyamqp witness against SHIMMED broker ==
[AFTER] witness connect + roundtrip SUCCEEDED (WITNESS_OK, no failure signatures)
== RESTORE: final sha256 verification of live connection.ex ==
[court] connection.ex byte-exact vs live snapshot: OK (42cec4e4…077d4)
VERDICT: NON-VACUOUS — unshimmed witness fails with the recorded signature, shimmed witness passes, restore byte-exact.
EXIT=0
```

Flock + live-baseline held: subject sha unchanged after the run
(`lib/smalt/messaging/amqp/connection.ex` = `42cec4e4f66fd4ed0b4ca704854d1bbd7d4950825a02cf71728c4c01d6c077d4`
before and after; the pristine pre-shim baseline is installed only under the held lock and
restored byte-exact).

### settle_cas — PASS (exit 0) after anchor repair (disclosed)

```
$ MIX_BUILD_ROOT=_build-lane311 just shim-court settle_cas
[SHIM] baseline sha256(lib/smalt/messaging/amqp/queue_store.ex) = 7bfdfaba149d53b9f09fadbc34ead6e1fa6488888702d2abd6b4871a30ca26ac
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/messaging/amqp/queue_store.ex (SHIM-COURT marker present)
[SHIM] AFTER: R244 zombie tests FAILED under shim as required (flip witnessed)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] settle_cas_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
EXIT=0
```

**Anchor repair disclosed.** The landed 725→739 re-anchor was still stale: in the current
`test/amqp/queue_store_test.exs` line 739 is spanned by the unrelated R160b
`receive_deferred` test, so the court's BEFORE/AFTER witness selected that shim-insensitive
test — the AFTER leg passed under shim and the court FAILED (exit 1) on first re-run. Minimal
repair: `R244_LINE=739` → `R244_LINE=742` in `scripts/shim_court/settle_cas_court.sh` (the
"complete with zombie token refuses :lock_lost" test). Witnessed twice: under the shim the
R244 zombie assertions fail (flip present); on pristine the test is green; subject restored
byte-exact (`queue_store.ex` = `7bfdfaba149d53b9f09fadbc34ead6e1fa6488888702d2abd6b4871a30ca26ac`
before and after every leg).

## Verdict

PASS for ets_cleanup, atom_bridge, amqp_framing, settle_cas (all non-vacuous, restore
byte-exact). disposition_token is a loud SKIP (exit 3) with the flip already landed in the
subject — standing PARTIAL_ALIVE with a named close condition, not a faked pass. One disclosed
one-line anchor repair to `settle_cas_court.sh` (739→742) was required to make its court flip.

## Addendum 2026-10-16 (r211b)

Standing: PASS (5 of 5 PASS; disposition_token SKIP resolved — no re-anchor needed)
Lane: milestone-doc lane 318 · 2026-10-16

Court-verdict gap closure for the four courts with no dedicated receipt, plus a
disposition_token re-run. All runs: `MIX_BUILD_ROOT=_build-lane318 just shim-court <name>`
on the current tree. Every court: non-vacuous BEFORE→SHIM→AFTER flip, RESTORE byte-exact,
exit 0 (PASS verdict per the exit-0/1/3 contract).

### lock_clamp — PASS (exit 0)

```
[SHIM] baseline sha256(gates/lock_clamp_gate.py) = ee4ff279546adc5dd5b6a5e2f0df66dccdf23ed2b8374867a2d2f14002960925
[witness] clamped obs verdict ok=True
[witness] unclamped-high obs verdict ok=False :: ['FAIL lockDuration PT1H (3600000ms): lock delta 3600000ms within clamped [29900,32000]ms']
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to gates/lock_clamp_gate.py (SHIM-COURT marker present)
[witness] clamped obs verdict ok=True
[witness] unclamped-high obs verdict ok=True :: no FAIL
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] lock_clamp_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```

### orphan_token — PASS (exit 0)

```
1 test, 0 failures (19 excluded)
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/messaging/amqp/lock_manager.ex (SHIM-COURT marker present)
[SHIM] AFTER: R178j test FAILED under shim as required (flip witnessed)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] orphan_token_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```

### blob_worm — PASS (exit 0)

```
[witness] refuse leg: mutated write against WORM-locked container REFUSED (409/ContainerLocked enforced)
[witness] refusal checks fired: FAIL overwrite under hold -> 409 (got 200); FAIL overwrite refusal carries ContainerLocked
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to /Users/sac/smalt/gates/blob_worm_gate.py (SHIM-COURT marker present)
[witness] admit leg: gate ADMITS the mutated write (refusal check absent) — flip observed
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] blob_worm_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```

### renew_mirror — PASS (exit 0, anchor now 566)

```
1 test, 0 failures (51 excluded)
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/messaging/amqp/lock_manager.ex (SHIM-COURT marker present)
[SHIM] AFTER: R194 test FAILED under shim as required (message re-availed; flip witnessed, see /tmp/r194_renew_mirror_after.log)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] renew_mirror_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
[SHIM] RESTORE verified byte-exact for co-subject lib/smalt/messaging/amqp/queue_store.ex
```

### disposition_token — PASS (exit 0; SKIP resolved without re-anchor)

```
1 test, 0 failures (13 excluded)
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/messaging/amqp/connection.ex (SHIM-COURT marker present)
[SHIM] AFTER: stale-token disposition test FAILED under shim as required (flip witnessed)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] disposition_token_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```

The r211 SKIP is obsolete: the landed `lock_token: dlv.lock_token` settle threading is back
in the subject (`lib/smalt/messaging/amqp/connection.ex` lines 2214/2221/2233), so the
court's plain grep anchor matches again and the court runs its normal flip protocol — no
`amqp_connection_baseline` re-anchor needed (a baseline install would have been a far larger
change; not attempted). The stale-token wire test passes pristine and fails under the shim:
non-vacuity re-witnessed on the landed tree. PARTIAL_ALIVE close condition met; standing for
this entry is now PASS.

## Verdict (r211b)

All five courts PASS (lock_clamp, orphan_token, blob_worm, renew_mirror, disposition_token),
each with a witnessed flip and byte-exact restore.
