# Receipt: S-1 lane — KD-21/KD-49 AMQP shims + mutation court

Subject: `/Users/sac/smalt` @ post-518b31a tree, 2026-10-15, lane S-1.
Status: LANDED (uncommitted, per lane discipline — coordinator owns commits).

## Identity

| file | sha256 (landing state) |
|---|---|
| `lib/smalt/messaging/amqp/connection.ex` | `2d2fb3b6eb9661a6ec99a95b7214f6186889952036c009051186220846315184` — court-verified subject. As-of-date note: S-2 layered further EH hunks (GAP-A2-03/04 annotations) AFTER the court run; all five S-1 hunks verified present post-merge (KD-21 marker, idle_time_out echo, KD-49 source/target echo, CBS dialect files untouched by that merge). The court verdict binds to the verified subject sha, not the moving tip. |
| `lib/smalt/messaging/amqp/cbs_router.ex` | `d255d6de88176e5f` (prefix; full sha at court snapshot) |
| `scripts/shim_court/amqp_framing_court.sh` | (this run: see court log `/tmp/s1-court-final.log`) |
| `scripts/shim_court/amqp_witness.py` | witness driver |

## Scope of change

Primary (per explore design E-2):

1. **KD-21** — `handle_amqp(:open, ...)`: the clamped `idle_time_out`
   (existing clamp logic, floor 60s / ceiling @recv_timeout) is computed
   BEFORE `send_frame` and echoed non-nil in the open reply map
   (`idle_time_out: idle`). The `|| @recv_timeout` fallback guarantees a real
   pad; nil would be trimmed by frame_codec's spec-legal trailing-null trim.
   frame_codec.ex untouched (attach stays trimmed; arity law preserved).
2. **KD-49** — `base_attach` gains `source: perf.source, target: perf.target`.
   The session case `Map.merge`s over these keys and still wins.

Disclosed companion shims on the same pyamqp wire tier (required for the
witness roundtrip to complete; all inside the court snapshot):

3. **CBS dialect** — `CbsRouter.check_type/1` admits pyamqp's
   `type: "jwt"` next to rhea's `servicebus.windows.net:sastoken`
   (`lib/smalt/messaging/amqp/cbs_router.ex`). Token verified identically by
   `SasVerifier`. One unit test updated to pin both the admitted `jwt` and a
   genuinely unknown type (`bearer`) (test/amqp/cbs_router_test.exs).
4. **Audience scheme normalization** — `authorized?/1` third lookup normalizes
   pyamqp's `amqps://127.0.0.1:PORT/entity` attach address to the `sb://`
   form the client's own CBS claim is keyed by
   (`connection.ex authorized?/1`).
5. **Settlement echo outcome** — the receiver-settlement disposition echo
   (`handle_disposition`) now carries the client's own terminal state (with
   `{:modified, fields_list}` rebuilt to the encoder's map form). The bare
   settled-only echo read as outcome `None` and failed every pyamqp
   complete/abandon/dead-letter settlement ("Expected 'accepted' but the
   reported outcome was: None"). Cross-lane disclosure: a broker-side crash in
   `FrameCodec.encode_modified_list` (frame_codec.ex untouched by this lane)
   was witnessed during cli5 probing and is fixed indirectly by rebuilding the
   list form into the map form before echo (no frame_codec.ex edit).

## Mutation court

`scripts/shim_court/amqp_framing_court.sh` (protocol of
`scripts/mutation_court.py`: BEFORE / AFTER / RESTORE, sha256 byte-exact
restore, exit 0 only if all phases pass, never fakes):

- BEFORE: connection.ex reverted to HEAD content, broker booted on private
  ports 39382/39474, real azure-servicebus (pyamqp) witness run.
  Result: rc=3 WITNESS_TIMEOUT — the recorded hang/detach signature of
  `test/sdk-python/.logs/pyamqp-attach-trace.log`.
- AFTER: shimmed bytes restored (sha256-verified vs snapshot), broker
  rebooted, witness runs a real provision→send→receive→complete roundtrip.
  Result: rc=0 SUCCESS.
- RESTORE: final sha256 = `2d2fb3b6...` byte-exact; post-restore all-hunks
  assertion (KD-21/49 + S-2's KD-18/19/20 hunks + KD-COVERS tokens) green.
- **VERDICT: NON-VACUOUS** (court exit 0, log `/tmp/s1-court-final.log`).

Court history (disclosed): 7 runs total; earlier runs failed on (a) sibling
lanes clobbering connection.ex mid-court 4x (coordinator serialized S-2),
(b) a `set -e`/`wait` ERR_EXIT abort in the court script itself (fixed),
(c) transient loopback ephemeral-port exhaustion (errno 49), (d) the
companion dialect gaps above. Each failure produced a code or protocol fix;
the final run is the verdict.

## Re-tests

| gate | command | result |
|---|---|---|
| mix | `mix test test/wire/amqp_wire_test.exs test/amqp/` | 279 tests, 0 failures (1 test updated: CBS jwt-type pin, disclosed above) |
| redteam | `bash test/redteam/r3_amqp/run.sh` | rc=0; 46 attacks, kill_tests=34, node --test pass 1 fail 0; POSTCHECK no new crash dumps (pre-existing dump noted) |
| smalt-cli pytest | `.venv/bin/python -m pytest tests/test_servicebus.py tests/test_eventhub.py -rs` | 1 passed, 4 skipped. `test_send_receive_batch_complete` PASSES (the KD-49 falsifier shape). Remaining skips: 1x SKIP-KD18 (allowed by mandate), 3x SKIP-KD49 detector still firing on legacy signatures — dead-letter/defer/lock probes hit `object of type 'UUID' has no len()` and related pre-registered detector signatures |

### Honest note on the remaining 3 SB skips

The SKIP-KD49 detector fires on pre-registered symptom strings. The
attach-echo fix itself is court-verified; the dead-letter probe fails on a
client-side `UUID`-encoding TypeError during the rejected-state settlement —
a distinct pyamqp-tier gap not covered by KD-21/49. Given sustained sibling
substrate contention (fresh substrates SIGTERM'd mid-boot repeatedly), the
residual gap is registered honestly rather than closed:

- Two test-only fixes disclosed in `smalt-cli/tests/test_servicebus.py`:
  per-message settlement (this venv's `complete_message` takes a single
  message, not a list) — that unblocked batch-complete from guaranteed-skip
  to PASS.
- A new KD row should track the dead-letter/defer/lock residual (UUID-len
  settlement path); not filed by this lane (KD numbering belongs to the
  coordinator).

## Lane-collision disclosure

- connection.ex was clobbered 4x by sibling writes; coordinator directed the
  sequence that landed the final merged content (S-1 KD-21/49 + S-2
  KD-18/19/20, KD-COVERS tokens). Snapshot-and-restore protocol preserved the
  merged file byte-exact through the court.
- Cross-lane compile unblocks under the compile-freeze SLA (disclosed):
  `lib/smalt/hw/frame.ex` gained `import Bitwise` (S-5's file, `<<<`
  undefined); S-5's `virtual_serial.ex` and S-2's `egress_router.ex` were
  mid-edit and recovered on their own; no other lane's file was rewritten.

## No commits. Landing state on disk. Court artifacts

- Court: `scripts/shim_court/amqp_framing_court.sh`
- Witness: `scripts/shim_court/amqp_witness.py`
- Court log: `/tmp/s1-court-final.log` (receipt table)
- Substrate log: `/tmp/s1-amqp-shim-court_substrate.log`
