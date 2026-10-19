# i29 capabilities.json drift — takeover verification (pair)

Context: pair(probe lane i29-capabilities-drift.md never landed; this receipt supersedes it)

Date: 2026-10-18 22:50 PDT · Context: pair(probe lane i29-capabilities-drift.md never landed; this receipt supersedes it)

## Standing: PASS (drift face closed, byte-identical regen confirmed on HEAD)

## Findings

- `docs/jira/v26.10.18/receipts/i29-capabilities-drift.md` does NOT exist — the
  probe lane never landed. This receipt takes over the face.
- Solo test, pre-regen-commit tree (build root `_build-ft-cap2`):
  `MIX_BUILD_ROOT=_build-ft-cap2 mix test test/canonical_projection_test.exs`
  → **20 tests, 0 failures** (22:50:20). No verbatim drift key captured: the
  test was already green, meaning the drift had been repaired moments earlier.
- Root cause of closure: commit `1eb89df` (22:49) "fix(projection):
  capabilities.json identity digests — pack-lock repin rider (regen, fence
  green x2)" landed the sanctioned regen
  (`MIX_ENV=test mix run --no-start -e 'Smalt.Projection.Canonical.write()'`).
  Prior commit `8552eec` (20:01) fixed the earlier silent regen failure
  (`:eaddrinuse`).
- Truth-vs-projection ordering verified on disk: `lib/smalt/registry.ex`
  (mtime 15:37, git-clean) and generated tables predate
  `docs/capabilities.json` / `docs/THIRD_PARTY.md` (both mtime 22:16).
  Truth side is committed, not in-flight — **no [IN-FLIGHT] condition**.
  (Only unrelated in-flight lib file: `lib/smalt/messaging/amqp/atom_bridge.ex`,
  owned by another lane, does not feed the projection.)
- `git diff --stat docs/capabilities.json docs/THIRD_PARTY.md` → empty; the
  rider delta is fully contained in commit 1eb89df. THIRD_PARTY.md freshness
  re-checked in the same write: current, no diff vs HEAD.
- Confirmation ×2 (post-1eb89df): same test command → **20 tests, 0 failures**
  (22:50, Finished in 2.1 seconds).

## Commands

```
MIX_BUILD_ROOT=_build-ft-cap2 mix test test/canonical_projection_test.exs   # 20 tests, 0 failures (x2)
git diff --stat docs/capabilities.json docs/THIRD_PARTY.md                  # empty (riders committed in 1eb89df)
git log -3 -- docs/capabilities.json lib/smalt/registry.ex                  # 1eb89df / 8552eec / 9c74de3
```

## Verdict

The 3-receipt drift face (i29-court-dry1, i29-wire-fresh2, i29-full-soak-c)
is CLOSED: projection riders are byte-identical to a sanctioned regen on
committed registry truth, and the fence is green ×2.
