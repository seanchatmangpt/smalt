# i29 — Pack-lock repin (`:lock_drift` resolved)

- **Date**: 2026-10-18
Context: pair(i29-replay-fences.md, i29-sdk-census-fresh.md)
- **Standing**: PASS — pack lock repinned to live pack identity; both replay fences 6/0 green; census drift face cleared.
- **Subject**: smalt working tree; file changed: `ggen_igniter.pack.lock` (1 line, sha256 field only). No git commit (coordinator commits).

## Drift

`ggen_igniter.pack.lock` pinned `smalt-substrate-pack` at `43c15edb…` while the
live checkout `../ggen-marketplace/packs/smalt-substrate-pack` computes
`a454f2f0…` (marketplace checkout moved — intended semantics: repin to live
identity). Surfaced as `:lock_drift` in i29-replay-fences (2 replay-test
failures) and in verify-all offline tier (i29-sdk-census-fresh).

## Repin executed

```
$ MIX_ENV=dev mix ggen_igniter.pack.lock --path ../ggen-marketplace/packs/smalt-substrate-pack --pack smalt-substrate-pack
locked smalt-substrate-pack sha256=a454f2f01f17a2c19ec48e1d52e8e011d035d54246785f7547a501e3557e5c6f
wrote ggen_igniter.pack.lock
```

Note: the task does not exist under `MIX_ENV=test` (`The task
"ggen_igniter.pack.lock" could not be found`); it resolves under `MIX_ENV=dev`.
Diff: 1 file changed, 1 insertion(+), 1 deletion(-) — only the sha256 field.

## Replay fences (post-repin)

Warm build root first (`MIX_BUILD_ROOT=_build-ft-rep2 MIX_ENV=dev mix compile`, exit 0 — per
i29-replay-fences cold-root timeout witness), then:

```
$ MIX_BUILD_ROOT=_build-ft-rep2 mix test test/smalt_registry_replay_identity_test.exs test/config_replay_identity_test.exs --include replay_identity
......
Finished in 82.7 seconds (0.00s async, 82.7s sync)
6 tests, 0 failures
```

Previously-failing assertions (registry + config pack-lock-vs-live fence, both
`:lock_drift`) now pass; byte-identical replay assertions unaffected (still PASS).

## Direct digest identity check

```
$ MIX_BUILD_ROOT=_build-ft-rep2 MIX_ENV=dev mix run -e '… GgenIgniter.PackLock.digest …'
pinned=a454f2f01f17a2c19ec48e1d52e8e011d035d54246785f7547a501e3557e5c6f
live=a454f2f01f17a2c19ec48e1d52e8e011d035d54246785f7547a501e3557e5c6f
match=true
```

## Census drift face

The verify-all census drift (`pack-lock 43c15edb vs live a454f2f0`) is the same
lock-vs-live fence exercised by `config_replay_identity_test` in the offline
tier — cleared by this repin (6/0 above + match=true). The full `just
verify-all` sweep was not re-run this session (multi-stage, concurrent-load
sensitive); the drift face itself is proven cleared by the direct digest check.

## Replay

```
MIX_ENV=dev mix ggen_igniter.pack.lock --path ../ggen-marketplace/packs/smalt-substrate-pack --pack smalt-substrate-pack
MIX_BUILD_ROOT=_build-ft-rep2 MIX_ENV=dev mix compile
MIX_BUILD_ROOT=_build-ft-rep2 mix test test/smalt_registry_replay_identity_test.exs test/config_replay_identity_test.exs --include replay_identity
```
