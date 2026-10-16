# fin-20-cleanup — lane doctor-dod session-residue cleanup

Date: 2026-10-15 · Lane: fin-20 · Repo: /Users/sac/smalt (no commits by this lane)

## Task

Clear the two doctor-dod WARNs: (1) orphan /tmp/smalt-substrate.lock holder,
(2) residual lane build roots; then rerun `just doctor-dod`.

## 1. Lock holder — kill guard fired, NOT killed (reported instead)

At task start the lock was held by `flock` pid 52775 (parent zsh 52751), whose
child `beam.smp` 52776 had 7 LISTEN sockets (`*:39643` arm, `*:39644` egress,
plus distribution ports). Per the kill guard: **do NOT kill — it has listeners.**

During the lane, the holder was replaced by an equivalent live process: `flock`
pid 76991 (ppid 1) → `beam.smp` 77090, again with LISTEN sockets
(`*:39643`, `*:39644`, + distribution ports). Verified via
`lsof /tmp/smalt-substrate.lock` and `lsof -nP -iTCP -sTCP:LISTEN`.

The holder is a live `mix run ... arm_port 39643 egress_port 39644` substrate
(`py-lane6` known-secret env, per its command line) — a foreign-lane substrate,
not an orphan. **WARN remains by design**; the WARN is accurate: the lock is
held by a process that is not a canonical 9443/8443 smalt listener.

## 2. lane-clean — 1.03 GiB freed, zero survivors

`just lane-clean` initially reported `DELETED 0 dirs` because the recipe's
`ROOT := parent_directory(justfile_directory())` resolved to `/Users/sac` (the
Justfile sits at the repo root, so `parent_directory` walks above the repo —
recipe bug, this session's fix). With the fix (`ROOT := justfile_directory()`),
the live-process guard (lsof +D + beam/elixir cwd scan) excluded nothing:

```
DELETED: _build-b6 (359732 KB)
DELETED: _build-enclave (359732 KB)
DELETED: _build-f16 (359732 KB)
DELETED 3 dirs, FREED: 1079196 KB (1.03 GiB)
```

Post-clean check: `ls -d _build-* | grep -v '^_build$'` → no matches
(`zsh: no matches found`), i.e. zero survivors. Canonical `_build` untouched.

## 3. doctor-dod after

```
summary: 0 FAIL, 1 WARN (exit 0 unless FAIL fired)
```

WARN count dropped 2 → 1. Remaining WARN (accurate, not clearable by this lane):
`orphan lock holder: /tmp/smalt-substrate.lock exists but no live smalt
listeners on ports [9443, 8443], holder pid=76991` — the holder's beam has
listeners on 39643/39644 (foreign-lane substrate), so the kill guard forbids
the kill.

## Diff

- `justfile.d/06-lane-cleanup.just`: one-line fix,
  `parent_directory(justfile_directory())` → `justfile_directory()`.

## Falsifier status

- Lock WARN falsifier: holder tree has no LISTEN sockets → then kill was lawful.
  Observed: LISTEN present twice, both times → refuse. Standing: WARN stays.
- Lane-root falsifier: `_build-*` present post-clean → observed absent. Cleared.
