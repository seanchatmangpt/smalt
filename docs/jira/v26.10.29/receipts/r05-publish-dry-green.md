# Receipt r05 — publish-dry GREEN (v26.10.29)

Standing: **ALIVE — `just publish-dry` exit 0, all four gates PASS.**

    -- gate 1: hex.build  PASS (tarball 1489920 bytes)
    -- gate 2: inner-tar key grep  PASS (0 matches)
    -- gate 3: leak grep (athena|/Users/sac)  PASS (0 hits)
    -- gate 4: gen_error_codes --check  PASS
    PUBLISH-DRY: exit 0

## What it took (both disclosed in commit c9)
1. gate 1 (was fatal since GL28-2, 28f9dcbe): graphlaw_ex gated
   only: [:dev, :test] — grounded in zero live code references (grep
   receipt) + the router's Code.ensure_loaded? guard + prod-compile
   falsifier (exit 0 without the dep).
2. gate 3: athena codename swept from 8 packaged surfaces (word-boundary,
   doc/comments only).

## Disclosed pre-existing findings
- config.ex mixes generated census + hand-written R8 law; `mix smalt.gen`
  deletes the hand block (witnessed, reverted). Burn-dir replay fence red
  vs regen on main, independent of this window. Owner: template split.
- Court ladder (test-offline) red in the concurrent lane's in-flight
  surfaces — r04 classification stands.

## Window close
9 atomic commits (a95b6f40..c9); ash-wave surfaces: 5/5 + 4/4 + 1/1 +
19/19 corpus + zero full-suite failures; publish-dry 4/4 PASS.
