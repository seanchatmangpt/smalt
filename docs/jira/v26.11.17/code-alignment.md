# code-alignment — smalt v26.11.17

Standing: PASS

## Identity
- Path: `/Users/sac/smalt`
- Branch at generation: main
- HEAD: 29bbcf0edf7edbc3ccb058a6623c7930c842c113
- Tracked files: 6337
- Tracked docs markdown: 2837

## Build manifests (tracked at the commit above)
- `mix.exs`
- `Justfile`
- `ggen.toml`
- `.tool-versions`
- `CLAUDE.md`
- `README.md`

## Top-level layout (tracked file counts)
- `.`: 27
- `.ggen`: 1
- `.ggen-v2`: 3
- `.ggen_igniter`: 11
- `.github`: 5
- `adapters`: 49
- `bench`: 15
- `bin`: 1
- `cli`: 19
- `config`: 10
- `designs`: 1
- `docker`: 24
- `docs`: 3521
- `examples`: 44
- `gates`: 10
- `ggen-marketplace`: 53
- `justfile.d`: 61
- `k8s`: 28
- `lib`: 748
- `mods`: 30
- `native`: 10
- `packs`: 10
- `parity`: 39
- `popcorn_actors`: 5
- `popcorn_demo`: 222
- `posh`: 220
- `priv`: 10
- `projections`: 2
- `proxy`: 7
- `rel`: 2
- `scripts`: 354
- `smalt-cli`: 118
- `src`: 18
- `templates`: 1
- `test`: 433
- `tests`: 1
- `verification`: 60
- `workspace`: 164

## Prior doc waves
- `docs/jira/v26.11.14`
- `docs/jira/v26.11.15`
- `docs/jira/v26.11.16`

## Falsifiers
- Any tracked path above absent at HEAD, or a count differing from `git ls-files`.
- HEAD sha not equal to or an ancestor of the live HEAD.

## Acceptance
```bash
python3 ~/zcode-cli/scripts/docs_v261117.py validate /Users/sac/smalt
```
Expected: exit 0 and `PASS`.

## See Also
- `~/zcode-cli/scripts/docs_v261117.py`
