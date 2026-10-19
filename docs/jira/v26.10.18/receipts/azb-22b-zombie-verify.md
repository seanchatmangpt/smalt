# AZB-22b — Zombie-fix verify (boot-stage ZOMBIE_BEAM closed)

Standing: **ALIVE — the ZOMBIE_BEAM jidoka face is closed on a real cycle set** (12/12 cycles CLEAN incl. the cycle-10 kill -9 recover fence; `validate_burn.py --gate` exit 0; zero zombie rows). The full 50-cycle ring (AZB-22 close condition) is NOT re-claimed here — this receipt verifies the repair, not the ring.
Context: solo(docker build smalt:local @f56ee6be + docker/burn/boot-burn.sh --planes all --cycles 12; no mix test, no git ops, no kills outside the harness)

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-22 (close condition) via the
repair lane's fix; verify lane per coordinator directive (azb-22b probe).
Prior typed RED: `docs/jira/v26.10.18/receipts/azb-22-burn-ring.md` (ZOMBIE_BEAM at
boot cycle 1 teardown: `beam.smp/epmd/erl_child_setup remains after stop: 116`,
jidoka line-stop).

## The repair under verification

`lib/smalt/affidavit/wasm_engine_supervisor.ex:204-211` — the Owner's old
`handle_info(_msg, state)` catch-all swallowed the supervisor's shutdown
`{:EXIT, sup, :shutdown}`; graceful stop never completed; beam survived >120 s.
Fix (commit `825657f`, present in HEAD lineage): the EXIT clause

```elixir
def handle_info({:EXIT, _sup, reason}, state) do
  {:stop, {:shutdown, reason}, state}
end
```

lets the owner terminate typed, so `bin/smalt stop` completes and teardown
zombie assertion (`no beam.smp/epmd/erl_child_setup remains`) passes.

## Identity chain (verified, not asserted)

- Fix commit `825657f` is ancestor of image subject `f56ee6be`
  (`merge-base --is-ancestor`: FIX_IN_IMAGE_SHA), of row subject `1339e053`
  (FIX_IN_ROW_SHA), and of live HEAD during this session.
- Image rebuilt this session: `smalt:local` `sha256:7055be8939427ec165…`,
  label `org.smalt.subject=f56ee6be53251c217fec5263b5e5c8c52f323a28`
  (`--build-arg SUBJECT_SHA` pinned; deps layers cached, lib-only delta).
- Head moved under the lane during the session (a8e8867 → c1ca250 → e916d767,
  concurrent lanes) — disclosed; boot-burn host mode pins rows to HEAD at
  run time, which is exactly the AZB-22 subject-moved law working as designed.

## Verification (real output, run 1792390200)

Command: `docker/burn/boot-burn.sh --planes all --cycles 12` (image `smalt:local`,
subject `f56ee6be`, digest `sha256:7055be8939…`). Exit **0**.

```
[boot-burn] === plane all: docker run (12 cycles) ===
[boot-burn] PASS: 12 cycles green, receipt=/burn-results/boot-all.jsonl
[boot-burn] host: gate-validating per-plane JSONL
[VALIDATE-BURN] …/boot-all.jsonl: OK
[boot-burn] PASS: planes=all cycles=12 tracked JSONL in docs/jira/v26.10.18/burn (run 1792390200)
```

Row census (`docs/jira/v26.10.18/burn/boot-all-1792390200.jsonl`, 39 lines =
header + 37 body rows + run_receipt):

```
{('boot','CLEAN'): 12, ('probe','CLEAN'): 12, ('teardown','CLEAN'): 12, ('recover','CLEAN'): 1}
teardown verdicts: 12 × CLEAN   (was: cycle 1 ZOMBIE_BEAM line-stop in azb-22)
recover: cycle 10 kill -9 → CLEAN, recovery_ms=11   (AZB-14 fence)
subject_sha in every row: 1339e05338986efa62d3ab6035d595ead40422fd (single)
image_digest in every row: sha256:7055be8939427ec165…  (single)
run_receipt identity.subject_sha: 1339e053…  standing: ALIVE (derived from replay)
python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/boot-all-1792390200.jsonl
→ OK, exit 0 (re-run by this lane, not just by the harness)
```

Every teardown row verdict CLEAN = "zero-listeners-no-zombies-no-crashlog":
after `bin/smalt stop`, no listener on any of the 6 plane ports and **no
beam.smp/epmd/erl_child_setup remains** — the exact assertion that typed
ZOMBIE_BEAM in azb-22. The graceful stop now completes; no >120 s hang.

## Accept status (honest)

- Zombie face closed: **MET** (12/12 teardown CLEAN incl. SIGKILL fence).
- Full ring all-green (AZB-22 close): **NOT claimed** — boot stage verified
  here; chaos ×50 / matrix N=8 / soak remain for the ring lane to re-run
  against the fixed image (chaos was already green in azb-22).

## Deviations / disclosures

1. Cycles=12 (not 50): bounded verify of the repaired face; full 50-cycle
   boot is the ring lane's stage to re-run.
2. Rows pinned to HEAD-at-run-time `1339e053` while the image subject is
   `f56ee6be` (HEAD moved mid-session under concurrent lanes). Fix commit
   `825657f` is ancestor of both — verified — so the image provably contains
   the repair; disclosed rather than silently mixed.
3. Concurrent `docker build` for `smalt-burn:latest` (another lane) ran
   during this build; different tag, no interference witnessed.
4. No git ops, no kills outside the harness, no _build deletion (lane law).
