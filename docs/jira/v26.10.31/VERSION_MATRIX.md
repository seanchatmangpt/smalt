# Version Matrix — v26.10.31

Standing: UNVERIFIED cells are marked; every cell below re-read from disk
2026-10-30 by the wave-2 kd-registrar lane (lane 18, WO-29/30/31).

| component | version | pin face | status | verified via |
|---|---|---|---|---|
| smalt | 26.10.31 | `mix.exs @version` | LANDED | `grep -n "26.10.31" /Users/sac/smalt/mix.exs` → mix.exs:4 `@version "26.10.31"` (WO-02 bump already on disk this window; re-grep at integration) |
| ash_graphlaw | 26.10.8 | `mix.exs @version` | FROZEN | `/Users/sac/ash_graphlaw/mix.exs:12` |
| graphlaw wasm engine | 26.10.28 | `priv/graphlaw/MANIFEST.json graphlaw_version` + wasm url pin | FROZEN | `/Users/sac/ash_graphlaw/priv/graphlaw/MANIFEST.json:3,8` |
| ash_pplan | 26.10.8-1 | `mix.exs @version` | FROZEN | `/Users/sac/ash_pplan/mix.exs:4` |
| xaas | 26.10.8 | `VERSION` file → mix.exs boot input | FROZEN | `/Users/sac/xaas/VERSION` = `26.10.8` |
| wasmex | 0.15.1 | hex pin | all four resolve 0.15.1 | smalt `mix.exs:170` `~> 0.15.1`; ash_graphlaw `mix.exs:238` `~> 0.15.1`; xaas `mix.exs:128` `~> 0.15` (lock 0.15.1); ash_pplan has no direct dep — `mix.lock` pins wasmex 0.15.1 via transitive hex resolution |
| xaas → ash_pplan git ref | 5f10c97 (origin/main, 2026-10-06 advance) | `mix.exs` dep ref | OPEN — advance decision owed | `/Users/sac/xaas/mix.exs:267-270` `ref: "5f10c9798b783c2023a6bfaa892c000630476f05"` |

## Version-sync gate

`/Users/sac/ash_graphlaw/gates/070_version_sync_contract.rq` exists
(confirmed by `ls` this window). Not run here (needs its own deps).
Note: any version bump must move `ontology.ttl` + all VersionBindings
together — a bump that moves `mix.exs` alone fails the version-sync gate.

## Falsifiers

- smalt bump: `grep -n "26.10.31" /Users/sac/smalt/mix.exs` at
  integration time (WO-02 lands the bump concurrently — verify before
  claiming).
- graphlaw engine + hex package versions move together via
  `gates/070_version_sync_contract.rq` on the ash_graphlaw checkout.
