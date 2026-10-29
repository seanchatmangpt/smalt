# BK-72 gates toolchain self-resolution — v26.10.21

**Standing**: **ALIVE (toolchain fix)** / **PARTIAL (full 6-gate sweep)** — the toolchain gap is fixed and proven before/after on blob-worm; the full `just invariant-gates` sweep was not re-run green because queue-capacity fails on real merits (pre-existing, matches BK-35's asdf run) and the shared tree carried sibling-lane compile freezes during the window.
- **Context: solo**

## Defect (from BK-35's environment finding)

`gates/common.py` spawned plain `mix`, which on this machine resolves to
Homebrew Elixir 1.19.5 / OTP-28, not the repo-pinned asdf
elixir 1.20.4-otp-29 / erlang 29.1.2 (`.tool-versions`). Every
substrate-dependent gate verdict was void — substrate died pre-bind in
~2s and the all-FAIL table looked like defects.

## Fix

`gates/common.py` now resolves the pinned toolchain itself
(`resolve_toolchain_env()`, module-level `TOOLCHAIN_ENV`):

- reads `.tool-versions` (`elixir` / `erlang` first lines),
- prepends `~/.asdf/installs/elixir/<v>/bin` and
  `~/.asdf/installs/erlang/<v>/bin` to the spawned-process PATH for
  BOTH spawn sites (`spawn_substrate` and `run_amqp_driver`),
- falls back to ambient PATH with a loud WARNING naming the unresolved
  versions if the asdf dirs are absent,
- prints `toolchain: elixir X / OTP Y (resolved from .tool-versions …)`
  at import in every gate report.

Both mix spawns in `gates/common.py` are covered. Sweep of the other
runners: no other `gates/*.py` spawns mix directly (all delegate to
`common.py`); `scripts/court_wire.sh` does not exist in the repo.

## Before / after (real runs, no manual PATH prefix)

BEFORE (ambient PATH without asdf shims, pre-fix):

```
$ env PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin python3 gates/blob_worm_gate.py
[gate] substrate port stolen pre-bind; re-picked all six -> 60289/... (attempt 2/3)
[gate] substrate port stolen pre-bind; re-picked all six -> 60298/... (attempt 3/3)
ERROR blob-worm: RuntimeError: substrate exited rc=127 before binding :60298
blob-worm: receipt ... verdict=FAIL
```

(rc=127 here because the stripped PATH had no mix at all; with the full
ambient PATH the Homebrew 1.19.5/OTP-28 mix resolves and dies rc=1
pre-bind — the BK-35 class. Both are pre-bind void verdicts.)

AFTER (plain invocation, post-fix) — first attempt hit a sibling-lane
compile freeze (`lib/smalt/storage/journal_sink.ex` mid-edit), typed by
the existing compile-freeze classifier; retried once the file compiled:

```
$ python3 gates/blob_worm_gate.py ; echo EXIT=$?
toolchain: elixir 1.20.4-otp-29 / OTP 29.1.2 (resolved from .tool-versions -> asdf installs)
PASS blob-worm/positive: ['PASS container created', ... 'PASS delete after hold release succeeds (lock was real)']
PASS blob-worm/fixture:snapshot-under-hold-accepted (refused: ...)
... (7/7 fixtures refused)
blob-worm: receipt /Users/sac/smalt/tmp/invariant-gates/blob-worm-receipt.json verdict=PASS
EXIT=0
```

Resolved-version lines printed by every gate report:

```
toolchain: elixir 1.20.4-otp-29 / OTP 29.1.2 (resolved from .tool-versions -> asdf installs)
```

## Driver spawn path (second site) exercised

`gates/queue_capacity_gate.py` (rides `run_amqp_driver`, the other fixed
spawn site) boots and captures for real under the resolved toolchain:

```
toolchain: elixir 1.20.4-otp-29 / OTP 29.1.2 (resolved from .tool-versions -> asdf installs)
FAIL queue-capacity/positive: ['FAIL broker closes with amqp:link-message-size-exceeded (got socket-closed)', ...]
3/3 fixtures refused (non-vacuous); verdict=FAIL, exit 1 — reproduced twice
```

Typing: this queue-capacity positive FAIL is **pre-existing, not
session-introduced** — it matches BK-35's real asdf-PATH run
("ledger-chain PASS; other 5 FAIL") and reproduces deterministically
across 2 runs with the toolchain resolved. Substrate boot + capture +
all fixtures ran on real merits; the divergence is broker-close
behavior (socket-closed vs amqp:link-message-size-exceeded), owner:
queue-capacity/AMQP lane.

## Verification ladder

- blob-worm (substrate boot + HTTP capture + 7 mutation fixtures): PASS exit 0, no manual PATH prefix.
- queue-capacity (driver spawn site): boots/captures under pinned toolchain; FAIL is a real pre-existing divergence, reproduced 2×.
- compile-freeze classifier exercised live (journal_sink.ex sibling edit) and correctly typed + survived retry.

## Falsifier / replay

```
python3 gates/blob_worm_gate.py        # PASS exit 0, prints toolchain line
python3 gates/queue_capacity_gate.py   # boots real; verdict FAIL is pre-existing
env -u HOME poetry 2>/dev/null; git diff gates/common.py   # the fix
```

Logs: `/tmp/bk72_q2.log`.
