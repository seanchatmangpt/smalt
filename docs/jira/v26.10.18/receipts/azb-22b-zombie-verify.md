# AZB-22b — Zombie-face verify (post-repair)

Standing: **PASS (zombie face clean post-cycle)** — with one disclosed
UNKNOWN input: the repair lane's `burn-ring --stage boot` retry was still
building its image at verify time (pid 94023, attempt 1, `mix deps.compile`),
so the ring **boot** stage's own re-verification is in flight elsewhere; this
receipt certifies the zombie face on the latest completed cycle (AZB-17
8x4 parallel matrix) plus the host-side orphan sweep.
Context: solo(port_sweep dry-run + docker/beam zombie scan after the in-flight
`parallel-matrix.sh --replicas 8` (pid 71013) completed its teardown; no kills, no git)

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-22/22b.
Prior RED: `azb-22-burn-ring.md` (typed ZOMBIE_BEAM at boot teardown,
deterministic `BEAM_STILL_ALIVE_120s`). Subject: `/Users/sac/smalt`,
HEAD `1339e05338986efa62d3ab6035d595ead40422fd`.

## Verification (real output, captured 2026-10-18 ~23:10 local)

1. **Waited for the in-flight cycle**: `parallel-matrix.sh --replicas 8`
   (pid 71013) plus its teardown `docker compose -f docker/burn/compose.burn.yml
   -p smalt-burn down -v --remove-orphans` (pid 78725) were running at lane
   start; lane blocked on pid 71013 exit before scanning. Result file:
   `docs/jira/v26.10.18/burn/parallel-matrix-8x4-1792389235.jsonl` — 64/64
   rows CLEAN (32 probe + 32 chaos, subject
   `d1298be513121ac1828b44b13eb77b8a084c7f75`, digest
   `sha256:14bbd68d6b42…`), embedded run_receipt replay
   `python3 scripts/validate_burn.py --gate …1792389235.jsonl` **exit 0**.

2. **Dead smalt-burn containers**: `docker ps -a --filter name=smalt-burn`
   → **0 containers** (before the scan, several had `Exited (0)` seconds
   after stop and were removed by compose `--rm`-style teardown; nothing
   lingers). `docker ps -a` full listing shows only non-burn containers
   (dbg-id*, kind nodes, act-sock-relay).

3. **Host orphan beam scan (tree-aware law)**: every live `beam.smp` with
   cwd `/Users/sac/smalt` holds a LISTEN socket (private-port lanes = live,
   not orphans). Explicit zombie scan — beam.smp with cwd ending `smalt`
   AND no LISTEN socket — returned **zero candidates**
   (`zombie_scan_done`, no ZOMBIE CANDIDATE lines). One transient beam
   (pid 64570, cwd=/Users/sac/smalt) exited during the scan and was gone
   when re-inspected (ps: no such pid). No `epmd` zombie faces.

4. **`scripts/port_sweep.sh` (dry-run) own verdict**:
   - orphan candidates section: 13× `SKIP pid …: live LISTEN in tree
     (private-port lane)` — all beams live in-tree;
   - stale epmd: none;
   - `nothing to kill`;
   - disclosed, not a beam zombie: `STALE pid-file: owner 40499 dead`
     (`/tmp/smalt.pid` legacy marker; substrate state is
     `/tmp/smalt-substrate-state/` per CLAUDE.md, so this is a stale
     scratch marker, not a live process). Canonical ports 9443/8443/5672
     held by `ssh` pid 61023 = the colima VM mux (`/Users/sac/.colima/_lima/colima/ssh.sock`),
     i.e. the docker transport itself, not an orphan beam.

## Why the zombie face is closed on this evidence

AZB-22's defect was a deterministic graceful-stop hang (beam survived >120 s
after `bin/smalt stop`, all listeners released but process remained). In this
cycle every burn container exited **(0) within seconds of the stop signal**
and compose removed all of them; the host carried zero smalt-cwd beams
without LISTEN sockets, and the sweep harness itself concluded
`nothing to kill`. The falsifier face ("beam survives stop") did not
reproduce on the post-repair tree.

## Accept status

- Ring completes a clean cycle without zombie beams: **met on the latest
  completed cycle** (matrix 8x4, 64/64 CLEAN, gate exit 0, zero residue).
- Zombie-face host scan: **met** (zero candidates; sweep `nothing to kill`).
- Ring `boot` stage re-run (the stage that originally RED'd): **in flight by
  the repair lane** (`/tmp/azb22b/ring-boot.log` pending; image build
  attempt 1 at deps.compile at verify time). This receipt does not claim
  that stage; if that run emits a non-CLEAN boot row, the zombie face
  reopens and this receipt's PASS is superseded.

## Deviations / disclosures

1. No kills performed; `port_sweep.sh` run dry-run only, per lane contract.
2. No git operations; HEAD read-only `1339e053`.
3. Concurrent-lane disclosure: the repair lane (build-loop pid 94023) was
   actively rebuilding `smalt:local` during this verify; the matrix cycle
   verified here ran on digest `14bbd68d6b42` at subject
   `d1298be513`, not the in-progress build.
