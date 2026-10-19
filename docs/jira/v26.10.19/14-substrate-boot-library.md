# V261019-14 — Substrate boot library: substrate_boot.sh + substrate-ctl

> **Status at materialization (2026-10-19):** IN FLIGHT —
> `scripts/lib/substrate_boot.sh` on disk (untracked, boot-library lane).

- **Release:** v26.10.19 · **Work order:** V261019-14 · **Plane:** Substrate lifecycle / lane harness (`scripts/lib/substrate_boot.sh` new, `substrate-ctl` CLI)
- **Scope owners:** `scripts/substrate.sh` (per-window flock manager, DoD-1 — *referenced, generalized, not rewritten*), new `scripts/lib/substrate_boot.sh`, new `substrate-ctl` entry (justfile recipe or `scripts/substrate_ctl.sh`)
- **Test surface:** `scripts/shim_court/boot_library_court.sh` (new, per `scripts/shim_court/lib.sh` protocol)
- **Docs surface:** `docs/TEST_ISOLATION.md` (boot section), `scripts/shim_court/README.md`

## 1. Law of the wall — fd-9 discipline (extraction, not invention)

**Ground truth.** `scripts/substrate.sh` already encodes the fd-9 law: lock acquired per-WINDOW, substrate spawned with the lock fd explicitly closed (`9>&-`), lock released on script exit while the substrate stays up, pid tagged in `$PID_FILE`; orphan lock-holders are killed via `tree_pids`/`tree_listening` (tree-aware: flock → mix → beam, two levels, one pid at a time per the R17/A11 pgrep argv lesson).

**Fix.** `scripts/lib/substrate_boot.sh` is the **library form** of that discipline, sourceable by every harness (SDK probes, burn scripts, census replay, sdk-results runners). Laws it enforces (each fail-closed):
1. **fd-9 law** — any child that must outlive the lock (`mix run --no-halt`, detached beam) is spawned `9>&-`; the library asserts post-spawn that no descendant of the boot pid holds the lock fd (rederive `lsof -t $LOCK` after boot; nonzero → kill + FAIL). This closes the witnessed PY-5 class (detached beam inherited fd 9 from its booting script and starved queued lanes — `docs/jira/v26.10.14/sdk-results/py-eventhub-eventgrid.md:22`, `test/sdk-python/run.sh:22`).
2. **Boot markers** — the library writes typed markers to the state dir: `boot.started`, `boot.ready` (all listeners present), `boot.failed` (reason), read by `status`/`logs`; courts read markers instead of scraping process tables.
3. **Formula blocks** — every boot declares its **port formula block** in a comment + parsed var, canonical form `vN = 39700 + 10N` (window/lane N; the current tree runs substrates on 3979x/39790–39799-class ports — e.g. census replay boots on 39792/39790), alongside the fixed listener set (ARM 9443/9444, AMQP 5672/5673). Port claims are checked against the formula and against live listeners before boot; a mismatch fails closed instead of colliding mid-court.
4. **Tree-aware orphans** — orphan detection always walks the process tree (flock → mix → beam), never `pgrep` with multiple pids as argv (R17/A11 #2 lesson preserved verbatim).
5. **Bounded poll** — readiness is a **250 ms bounded poll** on listener presence (`lsof` loop, deadline from `UP_TIMEOUT`), never a sleep ladder; observe, don't wait-and-hope (NO-SLEEP-DOCTRINE alignment: the poll is the lawful audited-poll class).

## 2. substrate-ctl — single entry

**Fix.** `substrate-ctl {up|down|status|logs|kill-orphans|verify}` wrapping the library:
- `up` — formula check → lock → spawn `9>&-` → bounded poll → `boot.ready` marker.
- `down` — tag-release: kill only the pid tagged in the pid file + its tree.
- `kill-orphans` — tree-aware sweep of lock/-port holders not matching the tagged pid.
- `verify` — re-derive lock holders, listeners, and markers; typed report; exit non-zero on drift.

**Fence:** `substrate-ctl up && substrate-ctl verify` → exit 0; `substrate-ctl down` leaves zero listeners and zero lock holders.

## 3. mjs / py wrappers

**Fix.** Thin runners `test/sdk-smoke/boot.mjs` and `test/sdk-python/boot.py` exposing `up()/down()/status()` (mjs: child_process spawn of `substrate-ctl`; py: `subprocess`) so JS and Python SDK harnesses stop hand-rolling boot/teardown (the divergence that produced the fd-9 leak class). Wrappers contain **no** boot logic of their own — any logic beyond argument passing is a review-refused diff (non-duplication R1 rule, WO-15).

**Fence:** census replay refactored onto the wrapper with identical probe results (11 probes / 12 tests green, replay receipt re-witnessed).

## 4. Starvation falsifier

**Fix.** `scripts/shim_court/boot_library_court.sh` (shim-court protocol, `with_shim`): non-vacuity proof that the fd-9 law is load-bearing —
1. BEFORE: boot via the library under a held lock; witness that no descendant holds the lock fd and a queued second boot is NOT starved.
2. SHIM: inject a spawn missing `9>&-` (marked SHIM-COURT) — reproducing the PY-5 leak.
3. AFTER: witness the lock holder appears in the descendant set / a second queued boot blocks past the bounded deadline.
4. RESTORE: byte-exact restore, sha256 equal baseline.

**Fence:** court exits 0 (BEFORE pass, AFTER flip observed, restore clean); `just shim-court boot_library` green and included in `just shim-courts` aggregate.

## 5. Sequencing

1 (library) → 2 (ctl) → 4 (falsifier against both) → 3 (wrappers + census refactor) → docs (TEST_ISOLATION boot section + shim_court README entry).
