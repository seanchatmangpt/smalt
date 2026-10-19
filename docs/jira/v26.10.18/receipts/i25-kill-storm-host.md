# i25 — kill_storm.sh: AZB-14 HOST-FORM precursor (SIGKILL storm + DETS repair + typed vocabulary)

Standing: ALIVE (live 3-cycle run 3/3 CLEAN, burn rows validate OK, sleep-gate PASS)

Repo: /Users/sac/smalt. Ticket AZB-14
(`docs/jira/v26.10.18/azsim-burn/TICKETS.md`). Host-form precursor of
`docker/burn/chaos-kill.sh` so the container form lands when AZB-13 does.
No git ops (coordinator owns transitions). Subject: tree @ main, commit `825657f`
at final run.

## What landed

- `scripts/chaos/kill_storm.sh` — host-side SIGKILL storm harness:
  1. Boots a PRIVATE-PORT substrate (c-law block **39620..39625**, env
     `SMALT_KS_PORTS_BASE`; no overlap with registered blocks 39520-25
     chaos_kill / 39000-series bench lanes) via
     `mix run --no-start --no-halt --eval` with
     `blob_storage: [persistence: :dets_mirrored, sync_interval_ms: 0]`
     (ack-before-fsync durability) — lane-private build root
     `_build-kill-storm`.
  2. Writes a blob ledger on the data plane under a write stream, SIGKILLs the
     beam at a seeded offset (LCG over `SMALT_KS_SEED`; seed in each row's
     detail), reboots on the SAME dets dir with `repair: true` (exercises the
     `needs_repair` repair path), then asserts:
     - every ledger-acked blob GETs 200 with byte-exact body (sha256),
     - a never-written blob answers typed `404 BlobNotFound` (never an
       untyped 500),
     - health/token/blob surface typed (no 5xx),
     - an i24-class closed-read probe of every `*.dets` with `repair: false`,
       bounded retry ONLY on the torn states (`{:needs_repair,_}` /
       `{:not_a_dets_file,_}`, 20x250ms = 5s budget per
       `receipts/i24-store-dets-torn.md`); any other open error fails the
       cycle.
  3. Emits one smalt-burn row per cycle (schema
     `docs/jira/v26.10.18/burn/burn-row.schema.json`) + `run_header` to
     `docs/jira/v26.10.18/burn/kill-storm-host.jsonl`, typed `broken_term`
     mapping for dirty verdicts (DETS_UNREPAIRED→mu_unlawful,
     UNHANDLED_EXIT→mu_on_O, TYPED_VOCAB_MISMATCH→admission_vacuous,
     TIMEOUT_DEADLINE→R_missing_consequence). Rows validate:
     `[VALIDATE-BURN] …: OK` (exit 0).
- Zero-sleep law: all waits are deadline polls (`SECONDS`-bounded
  `poll_until`); the poll step is `read -r -t` on a fd held open by
  `tail -f /dev/null` (POLL-STEP, no `sleep` literal anywhere in the script).
  `python3 scripts/sleep_gate.py` → `PASS — 330 files, 0 unclassified sleep
  primitives` (exit 0); `bash -n` exit 0.

## Session findings (mechanism, witnessed)

1. **Boot-order mirror race (fixed in harness; genuine seam finding).** With
   the naive ordering `ensure_all_started → DetsMirror.start_link → restore`,
   the first acked writes (c0 blob-0..4, c1 blob-0 in run
   `kill-storm-host-1792378921`) were LOST after SIGKILL + repair reboot: the
   listeners start inside `ensure_all_started`, so writes acked before
   `DetsMirror` is running no-op their `sync_write` ("no mirror => no-op",
   dets_mirror.ex:95-102) and are unmirrored at kill time. Losses were
   HEAD-shaped (first acked), not tail — what ruled out torn-bucket tail loss.
   Harness fix: start the mirror BEFORE the app, `restore()` after. Candidate
   seam for AZB-14 container form / AZB-06 owner: any boot path that starts
   listeners before the mirror admits unmirrored acks.
2. **Blob arms gate `x-ms-version`.** Data-plane blob PUT/GET without
   `x-ms-version` answer typed `400 MissingXMsVersion`; the harness carries
   `x-ms-version: 2021-12-02` on every data-plane call.
3. **`restore/0` returns `{:ok, map}`** (per-table row counts), not `:ok` —
   the boot eval must match `{:ok, _}` (a `:ok =` match crashed the boot).

## Validation (real output)

```
$ SMALT_KS_CYCLES=3 SMALT_KS_SEED=251018 bash scripts/chaos/kill_storm.sh
[KILL-STORM] run=kill-storm-host-1792379832 cycles=3 seed=251018 ports=39620..39625 jsonl=docs/jira/v26.10.18/burn/kill-storm-host.jsonl
[CYCLE 0] dets closed-read probe: PROBE [{"smalt_blobs.dets", :clean}, {"smalt_cosmos_docs.dets", :clean}, {"smalt_event_messages.dets", :clean}, {"smalt_ledger_meta.dets", :clean}, {"smalt_ledger_transactions.dets", :clean}, {"smalt_resources.dets", :clean}]
[KILL-STORM] cycle 0: CLEAN
[CYCLE 1] dets closed-read probe: PROBE [...same six files :clean...]
[KILL-STORM] cycle 1: CLEAN
[CYCLE 2] dets closed-read probe: PROBE [...same six files :clean...]
[KILL-STORM] cycle 2: CLEAN
[VALIDATE-BURN] docs/jira/v26.10.18/burn/kill-storm-host.jsonl: OK
EXIT=0

$ python3 scripts/validate_burn.py docs/jira/v26.10.18/burn/kill-storm-host.jsonl; echo $?
[VALIDATE-BURN] docs/jira/v26.10.18/burn/kill-storm-host.jsonl: OK
0

rows: 0 CLEAN None seed=251018 kill_at=63 acked=63 recover_ms=8000
      1 CLEAN None seed=251018 kill_at=63 acked=63 recover_ms=5000
      2 CLEAN None seed=251018 kill_at=63 acked=64 recover_ms=6000

$ bash -n scripts/chaos/kill_storm.sh; echo $?
0

$ python3 scripts/sleep_gate.py | tail -1
[SLEEP-GATE] PASS — 330 files, 0 unclassified sleep primitives
```

Evidence: `docs/jira/v26.10.18/burn/kill-storm-host.jsonl` (run_header + 3
CLEAN rows); per-cycle boot/reboot logs + ledgers under
`tmp/kill-storm/kill-storm-host-1792379832/` (scratch, untracked). Earlier
scratch run dirs deleted at integration.

## Schema-version disclosure

The task named `smalt-burn/v1`; the on-disk AZB-03 schema const is
`smalt-burn/v2` (`burn-row.schema.json` validates against it; REGISTRY notes
the v1 naming for the container-burn family). Rows are emitted as
`smalt-burn/v2` to validate against the tracked schema file; the discrepancy
is recorded here rather than minting a v1 file.

## Notes for the AZB-14 container form

- Port block 39620..39625 should be registered in
  `scripts/bench/REGISTRY.md` when the lane is promoted (host-form only for
  now; REGISTRY.md edit left to the register owner).
- The mirror-before-app boot ordering constraint transfers to the container
  boot (AZB-13/AZB-14).
- Non-CLEAN verdicts are signal, not harness failure: the seeded kill
  legitimately produces DETS_UNREPAIRED (lost acked) / TYPED_VOCAB_MISMATCH
  rows; `scripts/validate_burn.py` (non-gate) accepts them, `--gate` refuses
  them (AZB-03 semantics).
