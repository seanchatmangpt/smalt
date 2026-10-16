# 03 — Content-Addressed Lane Build Cache (contract-keyed shared `_build`)

**Release**: v26.10.15 · **Lane**: 03-lane-build-cache · **Status**: PLANNED
**Witnessed context**: `dod-06-lane-cleanup.md` — 61 orphaned lane roots, **33.71 GiB** freed by bulk delete; all were lease artifacts of per-lane `MIX_BUILD_ROOT` isolation.
**Environment**: Elixir/Mix 1.19.5, OTP 28, macOS (darwin 25.2.0).

## 1. Problem

Lanes need private compile dirs. Today: each lane gets its own `MIX_BUILD_ROOT`. Two failure modes:

1. **Orphan accumulation.** Every lane invocation on a cold hash mints a new full dependency tree; bulk delete throws away warm compilations identical future lanes could reuse.
2. **Env/port coupling.** Compiled-in port config (`SMALT_TEST_*_PORT`) can silently leak across lanes sharing a root keyed by lane identity instead of build contract.

Root cause: build roots are keyed by *lane identity* (who is building), not *build contract* (what is being built).

## 2. Move

```
contract-key = hash( mix.lock, config/test.exs, MIX_ENV, SMALT_TEST_*_PORT env )
tree         = _build-cache/<contract-hash>/
```

- Identical-contract lanes **SHARE** one managed tree (flock during initial compile only).
- Dissimilar contracts **diverge automatically** — no manual lane naming, no orphans.
- **GC by age + lsof in-use detection**, not bulk delete (`just build-cache-gc`).

## 3. Spec

### 3.1 Contract-hash computation

Canonical string, newline-terminated, fixed order, `LC_ALL=C`:

```
mix_lock=<sha256(mix.lock)>
config_test=<sha256(config/test.exs)>
mix_env=<MIX_ENV or "dev">
ports=<sorted k=v semicolon list of SMALT_TEST_*_PORT>
```

`contract-key = first 16 hex chars of sha256(canonical)`. Content-hash, not mtime (a touch-only bump must NOT diverge).

### 3.2 Env shim

**Verified on this machine (mix 1.19.5 / OTP 28):** the honored mechanism is the **`MIX_BUILD_ROOT` environment variable** (probe: `MIX_BUILD_ROOT=/tmp/nonexistent_probe_x mix run -e ':ok'` compiled deps there, confirmed on disk). **No `--build-root` CLI flag exists** on mix compile/run/test in 1.19. Commit to env only. Existing scripts (`fast_test.sh`, `dev_watch.sh`) already export `MIX_BUILD_ROOT` — the shim changes the value, not the mechanism.

### 3.3 Sharing-safety rules

1. Key on contract, never lane name: `MIX_BUILD_ROOT="_build-cache/<contract-key>"` (relative; mix resolves against repo root).
2. **mkdir-based spin lock** for initial compile only (flock absent on stock macOS): `mkdir _build-cache/<key>.lock` atomic on APFS; losers spin 0.2s re-checking dir existence, 10-min timeout then fail loud. Winner compiles, `rmdir` the lock. After the tree exists, no lock — concurrent `mix test` on a warm tree is safe (manifest-based recompile is reader-safe; the danger window is the initial dep compile).
3. No in-place mutation of a warm tree's contract state (`mix deps.update` etc.) — contract bumps get fresh trees.
4. Every invocation prints `BUILD_ROOT=<path>` + cache HIT/MISS to stderr.

### 3.4 GC policy (`just build-cache-gc`)

- Candidate: `_build-cache/<key>` dirs. Skip if live-referenced (`lsof +D _build-cache` scoped — whole-repo +D is slow; dropped files treated best-effort: false KEEP delays one cycle, age floor guards false DELETE).
- Delete if: not live AND (mtime older than `SMALT_CACHE_MAX_AGE_DAYS` (default 14) OR cache exceeds `SMALT_CACHE_MAX_GB` (default 10, evict oldest-first)).
- Never touch canonical `_build`. Per-dir disposition (KEEP/DELETE + reason) + total freed.

## 4. Falsifiers

1. **Share**: two concurrent same-contract lanes — A stderr `MISS`, B stderr `HIT`, same `BUILD_ROOT`, exactly one tree, one blocked on the lock (>0s wait line), both green.
2. **Diverge**: `SMALT_TEST_ARM_PORT=4100` → different key, different tree. Touch-only config mtime bump → SAME key (content-hash proof).
3. **GC**: old tree → DELETE; tree with a fake live beam cwd → SKIP.

## 5. Acceptance commands

```bash
( scripts/build_cache.sh mix test test/foo_test.exs & scripts/build_cache.sh mix test test/bar_test.exs ; wait )
SMALT_TEST_ARM_PORT=4100 scripts/build_cache.sh mix test test/foo_test.exs
just build-cache-gc-dry
just build-cache-gc
```

## 6. Files owned

| file | change |
|---|---|
| `scripts/build_cache.sh` | NEW — contract key, spin lock, `MIX_BUILD_ROOT` export + exec |
| `scripts/fast_test.sh` | EDIT — replace `_build-ft-<hash>` with the shim |
| `scripts/dev_watch.sh` | EDIT — route through the shim (keyed additionally on suite list) |
| `justfile.d/06-lane-cleanup.just` | EDIT — add `build-cache-gc`/`-dry`; keep `lane-clean` for canonical edge cases |
| `.gitignore` | EDIT — add `/_build-cache/` |
| `docs/jira/v26.10.15/receipts/03-lane-build-cache.md` | NEW — witnesses + exits |

## 7. Risks

- Concurrent compile of the same dep in a fresh shared tree is the only corruption window — closed by the mkdir spin-lock.
- Port config baked into beams — covered by the config hash; diverge witness 2 proves it.
- macOS `lsof +D` is slow and may drop open files — scope to `_build-cache`, treat as best-effort.
- First-share contention (both MISS cold) is the design working — print it.
- Never GC mid-`mix test` — the lsof guard covers beams running from the cache tree.
