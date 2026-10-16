# 01-substrate-lock — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
#
# Per-WINDOW flock substrate manager. Fixes the filed defect where the boot
# harness's beam inherited /tmp/smalt-substrate.lock's fd and held flock +
# ports forever after the harness exited. The lock is held only while
# spawning + verifying; the substrate runs lock-free, tagged with its pid.
# See scripts/substrate.sh and docs/jira/v26.10.14/receipts/dod-01-substrate-lock.md.

# Start the substrate holding the boot lock ONLY per-window (fd closed in
# the spawned beam). Verifies all 4 listeners + health before releasing.
# Exit 0 up / 2 boot failure / 3 lock not acquired. ~5-90s.
substrate-up:
    @bash scripts/substrate.sh up

# Stop the substrate (pid file + port holders + orphan lock-holder sweep)
# and verify all ports free. Exit 0 all free / 1 port still held.
substrate-down:
    @bash scripts/substrate.sh down

# Port probes + lock probe + orphan detection (lock held with no live
# listeners = ORPHAN; substrate-down clears it). Exit 0 always (report-only).
substrate-status:
    @bash scripts/substrate.sh status
