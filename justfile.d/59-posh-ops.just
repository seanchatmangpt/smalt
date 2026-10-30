# ============================================================================
# 59-posh-ops.just — POSH membrane process ops (lane P1, POSH-005 phase
# change: latent → gas). Companion to 58-posh.just (build/court ladder) —
# this module runs the BINARY as a long-lived process.
#
# Commands:
#   just posh-up     (build if needed; boot the posh binary as an OS
#                     process; bounded poll for the UDS socket)
#   just posh-down   (SIGTERM by pid file; bounded poll, then SIGKILL)
#
# Exit contract: 0 green / 1 FAIL / 3 SKIP — typed [POSH-OPS-*] lines.
#
# Honest preconditions: the posh binary is a standalone membrane (default-
# deny egress, local UDS only) and needs NO smalt substrate to boot. The
# SKIP path exists for the SMALT_POSH_BIN build toolchain (go missing).
#
# Concurrency: the spawn section runs under a mkdir-based atomic lock
# ("$STATE/lock"); concurrent posh-up invocations serialize, the loser
# exits 0 with the winner's membrane left running.
#
# House style: justfile.d/58-posh.just (typed exits, [no-cd] shebang
# recipes, POSHROOT via justfile_directory()).
# ============================================================================

POSHOPSROOT := justfile_directory()

SMALT_POSH_BIN    := env_var_or_default("SMALT_POSH_BIN", "posh/bin/posh")
SMALT_POSH_OPS_SOCK := env_var_or_default("SMALT_POSH_OPS_SOCK", "tmp/posh/ops.sock")
SMALT_POSH_OPS_STATE := env_var_or_default("SMALT_POSH_OPS_STATE", "tmp/posh/ops")

# Usage: just posh-up — build if needed; boot the posh binary as an OS
# process; bounded poll for the UDS socket (SKIP 3 when go is missing).

# posh-up — boot the posh membrane process, bounded-poll socket up.
[no-cd]
posh-up:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHOPSROOT}}
    BIN={{SMALT_POSH_BIN}}
    SOCK={{SMALT_POSH_OPS_SOCK}}
    STATE={{SMALT_POSH_OPS_STATE}}
    mkdir -p "$(dirname "$SOCK")" "$STATE"

    if ! command -v go >/dev/null 2>&1 && [ ! -x "$BIN" ]; then
      echo "[POSH-OPS-UP-SKIP] go not on PATH and $BIN not built — install go or run: just posh-build" >&2
      exit 3
    fi

    if [ ! -x "$BIN" ]; then
      echo "[POSH-OPS-UP] binary missing — building via make -C posh build"
      make -C posh build || { echo "[POSH-OPS-UP-FAIL] build failed" >&2; exit 1; }
    fi

    # --- already-up guard: pid must be non-empty, nonzero, alive AND socket
    # present. A stale pid file alone (C9 fix) is no longer "up".
    PID="$(cat "$STATE/posh.pid" 2>/dev/null || true)"
    if [ -n "${PID:-}" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null && [ -S "$SOCK" ]; then
      echo "[POSH-OPS-UP] already up (socket $SOCK, pid $PID)"
      exit 0
    fi

    # --- spawn under mkdir lock (atomic on POSIX) -------------------------
    LOCK="$STATE/lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
      # Bounded spin: 3s for the holder to finish (spawn is fast). If the
      # lock frees, retry once; if the membrane came up meanwhile, done.
      for i in $(seq 1 30); do
        mkdir "$LOCK" 2>/dev/null && break
        [ "$i" = 30 ] && { echo "[POSH-OPS-UP-FAIL] lock $LOCK held >3s by another posh-up" >&2; exit 1; }
        sleep 0.1
      done
      PID="$(cat "$STATE/posh.pid" 2>/dev/null || true)"
      if [ -n "${PID:-}" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null && [ -S "$SOCK" ]; then
        rmdir "$LOCK"
        echo "[POSH-OPS-UP] already up (won lock race — socket $SOCK, pid $PID)"
        exit 0
      fi
    fi
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

    # --- (re)spawn: kill any live previous instance first (C9 fix) --------
    OLD_PID="$(cat "$STATE/posh.pid" 2>/dev/null || true)"
    if [ -n "${OLD_PID:-}" ] && [ "$OLD_PID" != "0" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "[POSH-OPS-UP] live pid $OLD_PID exists — terminating before respawn"
      kill -TERM "$OLD_PID"
      for i in $(seq 1 50); do
        kill -0 "$OLD_PID" 2>/dev/null || break
        [ "$i" = 50 ] && {
          echo "[POSH-OPS-UP-FAIL] old pid $OLD_PID ignored SIGTERM within 5s — refusing to double-spawn" >&2
          exit 1
        }
        sleep 0.1
      done
    fi

    rm -f "$SOCK"
    # The binary resolves a RELATIVE socket path against its cwd, so chdir
    # to tmp/posh and name the socket relative there.
    SOCKDIR="$(cd "$(dirname "$SOCK")" && pwd)"
    SOCKNAME="$(basename "$SOCK")"
    printf 'socket: %s\ntcp_addr: ""\negress_allowlist: []\n' "$SOCKNAME" > "$STATE/posh.yaml"
    ( cd "$SOCKDIR" && nohup "$OLDPWD/$BIN" -config "$OLDPWD/$STATE/posh.yaml" \
        > "$OLDPWD/$STATE/posh.log" 2>&1 & echo $! > "$OLDPWD/$STATE/posh.pid" )

    # Bounded poll on the real observable (socket file), 10s deadline.
    for i in $(seq 1 100); do
      [ -S "$SOCK" ] && { echo "[POSH-OPS-UP] membrane up — socket $SOCK pid $(cat "$STATE/posh.pid")"; exit 0; }
      if ! kill -0 "$(cat "$STATE/posh.pid")" 2>/dev/null; then
        echo "[POSH-OPS-UP-FAIL] posh exited during boot — log: $STATE/posh.log" >&2
        tail -5 "$STATE/posh.log" >&2 || true
        exit 1
      fi
      sleep 0.1
    done
    echo "[POSH-OPS-UP-FAIL] socket $SOCK did not appear within 10s — log: $STATE/posh.log" >&2
    exit 1

# Usage: just posh-down — SIGTERM by pid file, bounded poll, then SIGKILL
# (C9 fix). Safe to run when nothing is up.

# posh-down — stop the posh membrane process by pid file.
[no-cd]
posh-down:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{POSHOPSROOT}}
    SOCK={{SMALT_POSH_OPS_SOCK}}
    STATE={{SMALT_POSH_OPS_STATE}}

    if [ ! -f "$STATE/posh.pid" ]; then
      echo "[POSH-OPS-DOWN-SKIP] no pid file at $STATE/posh.pid — membrane not started by posh-up" >&2
      exit 3
    fi
    PID="$(cat "$STATE/posh.pid")"
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "[POSH-OPS-DOWN] process $PID already gone"
      rm -f "$STATE/posh.pid" "$SOCK"
      exit 0
    fi
    kill -TERM "$PID"
    for i in $(seq 1 50); do
      if ! kill -0 "$PID" 2>/dev/null; then
        rm -f "$STATE/posh.pid" "$SOCK"
        echo "[POSH-OPS-DOWN] membrane down — pid $PID terminated, socket removed"
        exit 0
      fi
      sleep 0.1
    done
    # SIGTERM ignored past 5s → SIGKILL + 2s re-poll before failing.
    echo "[POSH-OPS-DOWN] pid $PID ignored SIGTERM within 5s — escalating to SIGKILL" >&2
    kill -KILL "$PID" 2>/dev/null || true
    for i in $(seq 1 20); do
      if ! kill -0 "$PID" 2>/dev/null; then
        rm -f "$STATE/posh.pid" "$SOCK"
        echo "[POSH-OPS-DOWN] membrane down — pid $PID killed, socket removed"
        exit 0
      fi
      sleep 0.1
    done
    echo "[POSH-OPS-DOWN-FAIL] pid $PID survived SIGKILL within 2s (stuck in uninterruptible wait?)" >&2
    exit 1
