# v26.10.20 Lane Partition — retro-registration

Retro-registration (2026-10-20, milestone-doc lane M4) of two wave partitions
on one canonical checkout (/Users/sac/smalt), registered after the fact from
on-disk receipts and the integration commit. Every claim cites a receipt or
commit on disk; nothing is asserted from memory.

## Wave A — popcorn Chicago-testbed 8-lane wave (2026-10-20)

Landed at commit `c72e47c` ("feat(testbed): popcorn_demo as Chicago
testbed — 8-lane wave, live substrate legs witnessed"), 2026-10-20
16:38:31 -0700, 25 files / +4442 −1818. Coordinator owned integration;
integration defects fixed en route are itemized in the commit message
(GET-with-body browser rejection, Fetch raw-body JSON decode, token leak in
FAIL clause, guard `=~` compile error, partial-receipt poll race, just
toolchain pin).

### Per-lane files owned

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| L1 | historical — partition not per-lane documented; disclosed a mid-write unblock of `live_blob.ex` (see disclosures below) | carried by commit `c72e47c` witness | commit c72e47c |
| L2 | historical — partition not per-lane documented | carried by commit `c72e47c` witness | commit c72e47c |
| L3 | `popcorn_demo/lib/popcorn_demo/live_blob.ex` (318 lines at lane time; 289 at c72e47c) | **ALIVE** (host legs: 3 consecutive green byte-equality runs; browser leg loud `SKIP(cors-preflight-403)`) | [receipts/popcorn-liveblob-lane-l3.md](receipts/popcorn-liveblob-lane-l3.md) |
| L4 | historical — partition not per-lane documented | carried by commit `c72e47c` witness | commit c72e47c |
| L5 | historical — partition not per-lane documented | carried by commit `c72e47c` witness | commit c72e47c |
| L6 | historical — partition not per-lane documented | per-lane doc absent | commit c72e47c |
| L7 | testbed witness harness: `popcorn_demo/scripts/receipt_testbed.sh` + `popcorn_demo/receipts/*.md` | witness chain 225630Z→233645Z: 5× SUSPECT (probe generations), 2× **ALIVE** (225824Z, 233645Z — final: 6 host tests, live=OK, matrix=OK, court PASS) | popcorn_demo/receipts/20261020T*.md; each carries `MIX_BUILD_ROOT=_build-lane7` |
| L8 | historical — partition not per-lane documented | per-lane doc absent | commit c72e47c |

The final witness receipt
[popcorn_demo/receipts/20261020T233645Z-testbed-witness.md](../../../popcorn_demo/receipts/20261020T233645Z-testbed-witness.md)
(standing **ALIVE**) is the wave-A landing witness cited by commit `c72e47c`.

### Compile-freeze disclosures (wave A)

- **L1 → live_blob.ex**: L1 disclosed a minimal mid-write unblock of
  `live_blob.ex` while L3 held the file. Recorded here per dispatch;
  the authoritative per-file truth is the c72e47c diff.
- **w6av (historical note, wave-6)**: a disclosed unblock is already
  recorded in source —
  [receipts/w6av-static-website.md](receipts/w6av-static-website.md)
  §"Compile-freeze SLA disclosure" (`account_from_blob_path/1` first-segment
  extraction added in the w6ay CORS region; flagged to w6ay). Not
  duplicated here; cited only.
- L3's own receipt discloses **none** ("fixed nothing outside my file")
  and names a transient `live_matrix.ex` compile break as a sibling lane's
  in-flight edit that recovered on its own (no SLA breach).

### Integration ownership (wave A, retro-registered to the coordinator lane)

| File | Owner |
|---|---|
| `popcorn_demo/lib/popcorn_demo/application.ex` | coordinator |
| `popcorn_demo/lib/popcorn_demo/smoke.ex` | coordinator |
| `popcorn_demo/lib/popcorn_demo/live.ex`, `transport.ex`, `live_matrix.ex` | coordinator |
| `popcorn_demo/scripts/browser_smoke.mjs`, `scripts/live_gate_court.sh` | coordinator |
| `Justfile`, `justfile.d/40-popcorn.just` | coordinator |
| `lib/smalt/arm_gateway/router.ex` + `lib/smalt/egress_router.ex` (CORS echo arms) | coordinator |
| `docs/TESTBED.md`, `popcorn_demo/README.md`, `scripts/README-testbed.md` | coordinator |

Per the lane-lease cleanup law, the following lane build roots were
deleted at c72e47c integration: `_build-lane1`, `_build-lane2`,
`_build-lane3`, `_build-lane7`, `_build-court`, `_build-integ`.
Residual leases observed on disk post-integration (untracked, popcorn_demo):
`popcorn_demo/_build-b3`, `popcorn_demo/_build-m1`,
`popcorn_demo/_build-lane7` — closure-wave leases, to be reclaimed by
`just lane-clean` at closure-wave integration.

## Wave B — 18-lane closure wave (opened 2026-10-20, post-c72e47c)

Retro-registered roster; wave B is the in-flight closure of the uncommitted
working tree (git status at registration: ~60 modified lib/test/docs files,
~21 untracked lib/test files). No per-lane receipts minted at registration
time — standing is **IN-FLIGHT** and flips are receipt-gated.

### Roster

| Lane | Focus | Standing at registration | Evidence |
|---|---|---|---|
| B1–B4 | popcorn_demo / browser-leg closure | IN-FLIGHT; leases `popcorn_demo/_build-b3` on disk | untracked build roots |
| T1 | test tree closure (internal/integration re-authoring) | IN-FLIGHT | untracked `test/internal/*`, `test/integration/*` files |
| M1–M4 | milestone-doc / matrix lanes | IN-FLIGHT; lease `popcorn_demo/_build-m1` on disk | untracked build roots; this file is M4 output |
| R1–R2 | router/registry closure | IN-FLIGHT | modified `lib/smalt/egress_router.ex`, `lib/smalt/` tree |
| S1–S2 | substrate/auth closure (health, auth, messaging) | IN-FLIGHT | modified `lib/smalt/health*.ex`, `lib/smalt/auth/*`, `messaging/amqp/*` |
| L-a, L-b, L-c | liveblob follow-ups / lane-doc lanes | IN-FLIGHT | untracked `popcorn_demo/test/live_blob_outcome_test.exs`; this file (L-c candidate) |
| A1 | adversarial/audit closure | IN-FLIGHT | — |
| coordinator | integration: composition of `application.ex`/`smoke.ex` and per-lane atomic commits | IN-FLIGHT | wave-A precedent c72e47c |

18 lanes total (17 named + coordinator).

### First closure-wave witness

[popcorn_demo/receipts/20261021T002527Z-testbed-witness.md](../../../popcorn_demo/receipts/20261021T002527Z-testbed-witness.md)
— standing **ALIVE**, host legs exit 0, browser leg skipped loudly
("skipped: public/out not cooked"). This is a witness, not a lane-closing
receipt; lane flips out of IN-FLIGHT are receipt-gated.

### Dependency order (wave B)

```
B1–B4, T1, R1–R2, S1–S2, L-a/b/c, A1 independent (disjoint files)
M1–M4 doc lanes last (register _LANES.md / RECEIPTS / FINAL reconcile)
coordinator integration terminal: lane-clean → commits → court-x2
```

### Shared seams (wave B, carried from wave-A law)

- `popcorn_demo/lib/popcorn_demo/live_blob.ex` — single writer per lane;
  any cross-lane fix is a disclosed unblock under the compile-freeze SLA
  (wave-A precedent: L1's mid-write unblock).
- `docs/jira/v26.10.20/_LANES.md` — this lane (M4) only.
- Generated docs (RECEIPTS.md, receipts/INDEX.md, FINAL.md) — wrap lane
  regenerates, never hand-edits.

## Shared-seam registration (coordinator, 2026-10-20, wave-3 audit F-2)

- `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md` is a REGISTERED SHARED SEAM:
  W3-1 owns the KD-124 row (line 17), W3-2 owns the KD-122 pointer row
  (line 15), W2-5 owns KD-123; coordinator owns status-column updates
  (KD-122 pointer now carries the canonical close cross-ref). Appends are
  row-scoped; no lane rewrites another's row.
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical): W3-2 owns the
  KD-122 row append; the flip status column changed only via
  `scripts/kd_flip.py --apply` (close_kd122.sh gate), never hand-edit.

## Waves 3–8 registration (milestone-doc lane M4, 2026-10-21)

Retro-registered appendix (same discipline as waves A/B above): per-wave
tables keyed on the dispatch lane IDs, standing taken ONLY from receipts on
disk; a lane with no receipt is **LANDING** (in-flight, receipt-gated).
Every file named below was `ls`-verified to exist at registration time.
Receipt-ID convention: `w<N><lane>` (e.g. `w5d` = lane W5-D).

### Wave 3 (testbed ERRC wave)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| W3-1 | KD register row KD-124 (v26.10.20 KNOWN_DIVERGENCES.md:17) — row scope only | row landed; row OPEN | row text on disk; popcorn-ERRC-ledger §Open Defects 3 |
| W3-2 | KD-122 pointer row (v26.10.20:15) + canonical KD-122 row append (v26.10.14:295) | CLOSED (pointer does not close; canonical flip via close_kd122.sh) | receipts/kd122-blob-cors-close-witness.md (PASS) |
| W2-5 | KD-123 row (v26.10.20:16) — row scope only | row landed; row OPEN | row text on disk; ERRC-R4 witness cited in-row |
| W3-E | KV purge bare-DELETE route, TLS twin (`lib/smalt/egress_router.ex` certificates-family routes) | PASS | receipts/w3e-kv-purge-bare-delete.md |
| W3-12 | `justfile.d/42-popcorn-bench.just`, `popcorn_demo/bench/legs.jsonl`, `popcorn_demo/bench/cook.jsonl` | ALIVE | receipts/w3-12-popcorn-bench-recipes.md |
| W3 remainder (A–D, F–11) | partition not per-lane documented on disk | historical (per wave-A law) | — |

### Wave 4

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| W4-E | SB rules ARM family (PUT/GET/DELETE/LIST witness) | PASS | receipts/w4e-sb-rules-arm.md |
| W4-4 | `popcorn_demo/lib/popcorn_demo/live_keyops.ex` + `popcorn_demo/test/live_keyops_test.exs` | PARTIAL_ALIVE (loud SKIP: `keyops=SKIP(es256:UnsupportedKeyType;rs256-witnessed-ok)` — HTTP create seam lacks EC dispatch) | popcorn_demo/receipts/20261021T025300Z-w44-keyops-witness.md |
| W4-13 | `popcorn_demo/scripts/secrets_gate.sh` (+ allowlist law) | PASS (gate ALIVE; non-vacuity flip proof in-receipt) | popcorn_demo/receipts/20261021T020000Z-secrets-gate.md |
| W4-15 | claim-count drift close (F-3) in `popcorn-ERRC-ledger.md` §"Verified counts (2026-10-21)" | receipted (83/86 figure is the standing count) | popcorn-ERRC-ledger.md |
| W4 remainder | partition not per-lane documented on disk | historical | — |

### Wave 5 (W5-A..K)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| W5-D | `lib/smalt/egress_router.ex` (certificates twin-family routes, exclusive) + `lib/smalt/data_plane/certificates.ex` deleted-family | ALIVE (zero-diff witness: w4g had landed the surface; w5d witnessed it, both legs) | receipts/w5d-deletedcertificates-witness.md |
| W5-H | closure-final witness harness run (substrate probe, receipt_testbed.sh, browser_smoke.mjs, mix test, live_gate_court.sh, receipt_index.py --check) | ALIVE (witness, not a lane-closing receipt) | popcorn_demo/receipts/20261021T013518Z-closure-final.md |
| W5-K | `lib/smalt/data_plane/certificates.ex` (owned; create plants pending LRO face) | ALIVE | receipts/w5k-certificates-pending-lro.md |
| W5-A, W5-B, W5-C, W5-E, W5-F, W5-G, W5-I, W5-J | no receipt on disk at registration | LANDING | — |

### Wave 6 (W6-A..J)

Wave 6 is the 53-receipt capability wave (WORK_ORDERS.md table is the
authoritative lane→receipt→standing register: 33 ALIVE + 20 PARTIAL_ALIVE);
this table registers the dispatch-letter lanes and the router seams, not a
duplicate of the WO table.

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| W6-A..W6-J (capability lanes) | per-receipt `lib/smalt/data_plane/*`, `lib/smalt/messaging/*`, `lib/smalt/mcp/*`, generated docs — see WORK_ORDERS.md | 33 ALIVE + 20 PARTIAL_ALIVE (receipt-derived) | receipts/w6* + WORK_ORDERS.md |
| W6-D | documentation-lane changes in `popcorn-ERRC-ledger.md` (owns docs only; 3 live-leg failures attributed to sibling lanes) | PARTIAL_ALIVE | popcorn-ERRC-ledger.md §Verified counts |
| W6-G | `lib/smalt/arm_gateway/router.ex` | LANDING (pending) | seam registration, this section |
| W6-H | `lib/smalt/egress_router.ex` | LANDING (pending) | seam registration, this section |
| w6R | `lib/smalt/egress_router.ex` structural split (BEAM limit fix; landed earlier in the wave) | ALIVE | receipts/w6R-router-split.md |

### Wave 7 (W7-A..E)

No receipts minted at registration time; all five lanes **LANDING**
(receipt-gated flips; no flip without a witness receipt postdating any
shim).

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| W7-A..W7-E | per-dispatch partitions; no receipt names files yet | LANDING | — |

### Wave 8 (W8-A..F)

No receipts minted at registration time; all six lanes **LANDING**.

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| W8-A..W8-F | per-dispatch partitions; no receipt names files yet | LANDING | — |

### Divergence-finish lanes K1..K8

Each Ki lane owns ONE canonical-register row scope (one writer per row;
flips only via `scripts/kd_flip.py --apply`, gated on a PASS witness
receipt postdating the shim mtime). Dispositions are row-scoped and
receipt-gated; **no K-lane receipt exists on disk at registration — no row
is flipped by this registration.**

| Lane | Row scope / disposition | Standing |
|---|---|---|
| K1 | blob/KV family row (scratch probes /tmp/k1_*: ACL, lease, SAS, list/del XML) | LANDING |
| K2 | cosmos family row (scratch /tmp/k2-*: collections, DB, feed) | LANDING |
| K3 | scratch /tmp/k3_scratch.exs | LANDING |
| K4 | probe scripts /tmp/k4b.sh, /tmp/k4probe.sh | LANDING |
| K5 | token/auth family (scratch /tmp/k5_*) | LANDING |
| K6 | no on-disk trace at registration | LANDING |
| K7 | scratch /tmp/k7-snap.mjs + /tmp/k7-token.json | LANDING |
| K8 | no on-disk trace at registration | LANDING |

/tmp scratch files are evidence-of-activity, never standing; /tmp is not a
receipt store.

### Shared-seam additions (waves 3–8)

- `lib/smalt/policy.ex` — **coordinator-owned** for the KD-125 scope
  (8 `# KD-COVERS: KD-125` sites on disk at registration); policy-list
  close witness: receipts/kd125-policy-list-close-witness.md (PASS);
  KD-125 CLOSED-SIMULATED in the canonical register.
- `lib/smalt/arm_gateway/router.ex` — **W6-G, pending** (landing).
- `lib/smalt/egress_router.ex` — **W6-H, pending** (landing). Note the
  prior w6R split (ALIVE) and the standing KD-COVERS shim inventory in
  this file (KD-15, KD-53, KD-60, KD-97, KD-122, KD-123 sites on disk);
  single writer per lane, cross-lane fixes are disclosed unblocks under
  the compile-freeze SLA.
- KD register row scopes (unchanged from the wave-3 audit section above):
  W3-1 → KD-124 row, W3-2 → KD-122 pointer + canonical append, W2-5 →
  KD-123 row; coordinator owns status-column updates only. K1..K8 own
  their assigned canonical-row finishes; kd-registrar owns mints.

### SCVD lanes T1..T15

SCVD (stress/chaos/verdict-diversity) wave registration, compiled from
on-disk evidence 2026-10-21. Standing per `tmp/bench/*.jsonl` disk
truth, not dispatch claims; full numbers in
`receipts/scvd-wave-summary.md`. No KD rows flipped by this
registration.

| Lane | Evidence file | Standing | Note |
|---|---|---|---|
| SCVD-T1 | `tmp/bench/scvd-tier1.jsonl` | PASS | cosmos 16-leg put/get; 3 rows, 0 errors, ~2.4–2.5k ops/s |
| SCVD-T2 | `tmp/bench/scvd-tier2.jsonl` | PARTIAL_ALIVE | PASS at n=1024; three n=512 rows are recorded harness-defect rows (`errors: 512`, standing FAIL) |
| SCVD-T3 | `tmp/bench/scvd-tier3.jsonl` | PASS (wall found) | wall at L8192 (`wall-summary`, `typed_fail_512: true`); ramp-8192 row carries 534 errors |
| SCVD-T4 | `tmp/bench/scvd-tail.jsonl` | SUSPECT | `INVARIANCE-BREACH`: p99 c128/c1 ratio 188.79 vs fence 10; 0 errors |
| SCVD-T5 | `tmp/bench/scvd-chaos-conn.jsonl` + `receipts/scvd-t5-conn-exhaustion-chaos.md` | PARTIAL_ALIVE | run 2 PASS (recovery 594 ms); run 1 FAIL (cert-verify recovery error); refusal class `accepted-all` |
| SCVD-T6 | `tmp/bench/scvd-wasm-vs-host.jsonl` | ALIVE | 2 PASS rows + 1 PARTIAL_ALIVE (no host ramp-256 row); op classes differ, ratio indicative |
| SCVD-T12 | `tmp/bench/scvd-blob.jsonl` | PASS | witnessed on disk contrary to dispatch "pending"; 3 rows PASS, cold row 278.3 ops/s |
| SCVD-T7..T11, T13, T14 | none on disk | UNWITNESSED | no jsonl in `tmp/bench/`; no standing asserted |
| SCVD-T15 | `receipts/scvd-wave-summary.md` | PARTIAL_ALIVE | this summary lane; disk-truth compilation only |

/tmp scratch files and dispatch prose are not evidence here; the jsonl
files above are the receipts of record. T4's invariance breach and
T5's run-1 recovery failure are OPEN observations until closing
receipts retire them.

### POWL 2.0 wave (lanes POWL-1..POWL-12)

Registration compiled from disk 2026-10-21 ~12:18 PT; full per-gate
table, skeptic OPEN items, and incident record in
[`POWL2.md`](POWL2.md). No KD rows flipped by this registration; V1
(POWL2 gate court receipt) stays PENDING until a witnessed court
receipt lands.

| Lane | Owned surface | Standing (disk) | Note |
|---|---|---|---|
| POWL-1 | `lib/smalt/petri_net.ex`, `test/internal/petri_net_test.exs` | ALIVE (18/18 current-run) | skeptic marked UNWITNESSED at audit time; test file landed in 92e49af |
| POWL-2 | `lib/smalt/powl2/compiler.ex`, `test/internal/powl2_compiler_test.exs` | BUILD_BROKEN | compiler.ex landed 12:17:51 with SyntaxError:81; HIGH-1/HIGH-2 OPEN against md5 f8e5a21f ancestor |
| POWL-3 | `lib/smalt/powl2/projection.ex`, `test/internal/powl2_projection_test.exs` | ALIVE (8/8, powl3-projection.md) | file untracked — clean hazard |
| POWL-4 | `lib/smalt/powl2/change_feed.ex`, `test/internal/powl2_change_feed_test.exs` | ALIVE (8/8 current-run), UNWITNESSED by receipt | compile-freeze healed by owner (executor receipt discloses) |
| POWL-5 | `lib/smalt/powl2/decomposition.ex` + test | IN-FLIGHT | 12:12 run 0/4; file rewritten 12:15:35, no post-rewrite run |
| POWL-6 | `lib/smalt/powl2/reticle.ex` + test | PARTIAL_ALIVE — **PENDING-RETAUTH** | skeptic live-probe PASS; current run 16/17; file untracked |
| POWL-7 | `lib/smalt/pplan/receipt_engine.ex`, `task.ex` + test | PARTIAL_ALIVE | merkle suite 6/6 (skeptic + current run); DETS chain path UNWITNESSED |
| POWL-9 | `lib/smalt/powl2/executor.ex` + test | ALIVE (7/7, powl9-executor-kernel.md) | double-deletion incident disclosed in receipt |
| POWL-12 | `receipts/powl2-wave-skeptic.md` (read-only audit) | receipt of record | HIGH-1/HIGH-2 are OPEN until closing receipts land against the landed compiler |

Incident: untracked lane files git-clean-deleted twice mid-session;
protective checkpoint 92e49af (16 files, 3,035 insertions) at 12:06:29
PT. `reticle.ex`, `projection.ex`, `compiler.ex`, `change_feed.ex`
remain untracked at registration time — coordinator checkpoint advised
before any clean.
