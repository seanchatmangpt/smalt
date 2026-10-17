# v26.10.16 RESOLUTIONS — Shared Seams

Cross-lane seam resolutions. Per `same-checkout-fanout`: shared seams are recorded here,
one entry per seam, owning lane named, falsifier stated.

## S1 — AMQP attach arity pinion vs 7-field Target composite (R16/R43/R57/R58)

- **Seam**: CLAUDE.md wire pinion says "14-field attach with omitted locale fields". R16
  changed the `:target` composite from 8 → 7 fields (pyamqp `Target` namedtuple arity).
  R43 tightened the parity assertion to `== 14`; the wire attach top-level list is
  spec-legally trimmed of trailing nulls (§1.4.3), so the landed assertion is `<= 14`
  (R57) with per-performative ceiling guards (R58).
- **Resolution**: the pinion's substance is the locale-omission / 16-field-crash fence,
  NOT an exact top-level count. `<= 14` + composite-level tripwires (source=8, target=7)
  preserve it. Pinion wording landed in CLAUDE.md this pass ("attach top-level <=14 with
  locale fields omitted (source=8/target=7 composite arity tripwires)"); test tier is the
  binding fence.
- **Owner**: coordinator. **Falsifier**: any test asserting attach top-level arity == 14,
  or a composite arity tripwire regressing (source≠8 / target≠7), fails.

## S2 — court_x2 judge_log compile-abort pattern (R35/W2)

- **Seam**: R35's judge_log greps literal `== Compilation error ==`, but real mix output
  is `== Compilation error in file lib/x.ex ==`; an aborted run with a stale
  "0 failures" line can still judge GREEN.
- **Resolution**: widen the patterns (match `== Compilation error` prefix + keep
  ` compilation failed`); add a witness court proving the widened form flips on a real
  compile-abort log.
- **Owner**: repair lane (court_x2.sh). **Falsifier**: synthetic abort log with
  `== Compilation error in file …` + "0 failures" judged GREEN.

## S3 — EH container-metadata set-at-create (R19/R62 receipt seam)

- **Seam**: create-time `x-ms-meta-*` seeding discards its result at
  `egress_router.ex:1022`; R19's receipt shows `get_container_metadata/2` → `%{}`
  after set-at-create. ST6 D1 (:819) is green but the binary-PUT metadata variant
  (blob_hardening_test.exs:819 area) still loses the metadata.
- **Resolution**: propagate create-time metadata through the WORM-safe path (fresh
  containers have no hold/locked-policy row, so the gate cannot refuse a legitimate
  create-time seed); stop discarding the result.
- **Owner**: repair lane (blob_service.ex + egress_router.ex). **Falsifier**: create
  container with `x-ms-meta-env: prod` → GET properties carries it (V11 failure
  egress_wiring_test.exs:197/221).

## S4 — settle-token contract: QueueStore settle arities + optional :lock_token (R196/R201)

- **Seam**: three lanes touch the settle path — R196 adds token-scoped
  compare-and-settle in `queue_store.ex:339-344` (optional `opts[:lock_token]`),
  R201 threads the delivery's live token through `connection.ex` settle/2
  (`complete`/`release`/`deadletter` at connection.ex:2001/:2008/:2020, captured
  per-delivery at :1803), and the `settle_cas_court.sh` shim asserts the flip. The
  seam is the QueueStore settle arity contract: the no-opts form must keep working
  (legacy callers/tests) while the opts form refuses zombie tokens typed
  `:lock_lost` without touching the message row.
- **Resolution**: `opts[:lock_token]` is OPTIONAL — omitting it preserves the
  pre-R196 semantics (suite stays green for legacy arities); passing it upgrades to
  CAS. R244 zombie tests at `queue_store_test.exs:739+` (7-test describe block,
  court-anchored at `R244_LINE=739`) are the binding fence; the court's BEFORE/AFTER
  legs witness both forms. Court anchor note: the earlier `R244_LINE=725` FAIL was a
  stale anchor in the court script, not a lib defect — anchors must track the
  describe block, not a line pinned pre-edit.
- **Owner**: repair lane (queue_store.ex + connection.ex); court owner:
  settle_cas_court.sh. **Falsifier**: a settle carrying a stale/zombie token that
  succeeds and mutates the message row, or a legacy no-opts settle call that now
  errors, fails. Witness: r188-r196-r197-worm-settle-batch.md (amended) +
  r187b-r190-court-hardening-batch.md.

## S5 — tombstone-grace contract: sweeper vs LockManager token lifetime (R197)

- **Seam**: `sweeper.ex:35-63` re-puts an expired `:message` token as a tombstone
  after a sweep (grace bounded by `amqp_sweeper_lock_grace_ms`, default 30_000), so
  LockManager renew/settle on a just-swept token must answer typed `410 :lock_lost`,
  never raw `404`. The seam is sweeper vs LockManager token lifetime: the sweeper
  re-put must NOT restore the ORIGINAL expiry (that would resurrect a dead lock);
  queue_store_test.exs:543 pins the flipped assertion (tombstone with original
  expiry, or :error once past grace).
- **Resolution**: tombstones carry grace-window semantics, not original-expiry
  semantics; renew/settle paths read the tombstone and answer `:lock_lost` within
  grace. Witnessed by `tombstone_grace_court.sh` (non-vacuous, restore byte-exact)
  plus the standalone sweeper suite 5/0 (r188-r196-r197 receipt). Renew→message-row
  mirror (R194, queue_store_test.exs:564) composes: a renewed token must not be
  swept under the sweeper's feet.
- **Owner**: repair lane (sweeper.ex); court owner: tombstone_grace_court.sh.
  **Falsifier**: a renew on a just-swept token answering 404 (grace absent), or a
  tombstone extending the lock's original expiry past `amqp_sweeper_lock_grace_ms`,
  fails.

## S6 — courts vs test tiers serialize on shared subjects (WRAP_LEDGER operational law)

- **Seam**: shim courts mutate live `lib/` subjects (connection.ex, event_hubs.ex,
  sweeper.ex, queue_store.ex) mid-flight; concurrent wire/full-tier test lanes read
  the same files. Witnessed twice 2026-10-16: (1) amqp_framing_court traded the live
  connection.ex against a stale Oct-15 snapshot mid-window → phantom 14-failure wire
  run (adjudicated VOID — quiet tree 381/0, lane281); (2) disposition court read the
  same window as a loud subject-degraded SKIP. The seam is shared file subjects
  between court processes and test lanes.
- **Resolution**: courts flock per-subject; wire/full-tier lanes must wait for court
  processes to drain (poll shim-court locks) before trusting a red run. A mid-shim
  signature is subject sha256 INSTABILITY + live shim-court processes — not
  SHIM-COURT marker presence (landed code carries markers too). Canonical:
  WRAP_LEDGER.md "Operational law (witnessed 2026-10-16)".
- **Owner**: coordinator (serialization is a lane-scheduling concern, not owned by
  any one lane). **Falsifier**: a red test run adjudicated against a tree whose
  subject sha256 was changing under it (any future phantom-failure adjudication
  that skips the sha256-instability + live-court-process check) fails.

## S7 — EH batch discriminator shape: duplicate-KIND vs count heuristic (R185e, KD-53)

- **Seam**: R166's count-based multiplicity check assumed an inner-message section
  count that the real `@azure/event-hubs` SDK shape
  `[header, message_annotations, properties, application_properties, body_data]`
  (5 sections) violates — resurrecting the KD-53 silent drop of inner events 2..N.
  The seam is the `batch_inner_messages` contract in `event_hubs.ex`: boundary
  detection must accept the SDK's real inner shape while still failing closed.
- **Resolution**: R185e replaces the count heuristic with duplicate-section-KIND
  detection (repeated AMQP section KIND within one inner group marks the group
  boundary) + shape-sequence homogeneity validation; any group failing inner decode
  falls back to ONE event — never a silent partial drop. KD-53 row stays
  CLOSED-SIMULATED (shim + witness already registered; R185e is a mechanism rewrite
  on the same seam, not a register flip). Witnessed: event_hubs_test.exs 26/0 +
  eh_batch_court + wire_norm court non-vacuous (r185e receipt).
- **Owner**: milestone-doc lane (event_hubs.ex). **Falsifier**: a real-SDK-shaped
  5-section inner message whose events 2..N are dropped, or a malformed group that
  silently yields a partial batch instead of ONE event, fails.
  Receipt: r185e-eh-batch-dup-kind.md.
