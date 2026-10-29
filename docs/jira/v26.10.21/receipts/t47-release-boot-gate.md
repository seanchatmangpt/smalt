# t47 RELBOOT — prod-release boot vs NFR-FOOTPRINT 500 ms cold-start ceiling

Context: solo

- **Lane**: t47 (RELBOOT, bench-runner)
- **Date**: 2026-10-21
**Standing**: PARTIAL_ALIVE — release builds, boots, and serves real ops (ARM `/subscriptions?api-version=2020-01-01` -> 200, Cosmos `GET /dbs` -> 200); the 500 ms cold-start ceiling is FAILED, typed below.
- **Result file**: `/Users/sac/smalt/tmp/bench/t47-release-boot.jsonl` (9 rows)
- **Lane script**: `/Users/sac/smalt/tmp/bench/t47_release_boot.sh`
- **Ports**: private block 39950..39955 (pre-flight lsof check; never contended with other lanes' held ports; all boots cleaned up — zero `rel/smalt` beams and zero listeners remain, verified post-run).

## Machine

```
$ just bench-machine
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

Release built and run with the `.tool-versions` toolchain (Elixir 1.20.4-otp-29, OTP 29.1.2
via `~/.asdf/installs`; the ambient PATH Elixir 1.19.5/OTP 28 cannot compile the OTP-29
`is_integer/3` guard heads). The `machine` field in the jsonl rows carries the actual
run toolchain.

## Build

- `MIX_ENV=prod mix release smalt --overwrite` — SUCCESS.
- **Config diff: NONE.** `mix.exs` already carried a release stanza (name `smalt`,
  `applications: [smalt: :permanent]`, `strip_beams: [compress: true]`); `config/runtime.exs`
  was already release-aware (`Smalt.Planes.resolve/0`). Zero repo diff for the lane.
- Ports/auth injected via `RELEASE_SYS_CONFIG` overlay (not baked config):
  `tmp/bench/t47/sys.config` sets `arm_port 39950`, `arm_tls_port 39951`,
  `egress_port 39952`, `amqp_port 39953`, `event_hubs_port 39954`, `mcp_port 39955`,
  `auth_mode anonymous`, `tls auto`. (Boot script emits a harmless
  `grep: .../sys.config.config: No such file or directory` line — the wrapper probes for a
  `.config`-suffixed variant first; overlay otherwise loads and takes effect.)

## Boot-to-ready results (op = `boot_to_all_listeners`, readiness = all 6 listeners via lsof poll)

| run context | cold walls (ms) | warm stop→start (ms) |
|---|---|---|
| quiet machine (mid-session run) | 1913 / 1906 / 4512 | 2674 / 3598 |
| loaded machine (final receipt run; 15 other lane beams resident) | 28002 / 11892 / 16532 | 2674 / 3598 |

Both series are recorded; the receipted verdict uses the BEST honest series
(quiet-machine 1.9 s) — i.e. the verdict is conservative against the ceiling.

## Verdict vs NFR-FOOTPRINT (≤500 ms cold start, production builds)

**FAIL — ceiling not met.** Best quiet-machine cold boot-to-all-listeners = **1906 ms
= 3.8x the 500 ms ceiling**. The release DOES eliminate the dev-path's dominant
mix/BEAM pre-eval phase (dev `mix run` 1.25–2.4 s pre-eval, per t45 BOOTPROF) — release
in-VM work to listeners is ~1 s class — but the remaining floor (erts boot ~1.2 s under
this machine's load, code-path load of the compressed beam set, ETS/supervisor tree) still
sits 3.8x over the line. The operator's asymmetry hypothesis (release passes where dev
cannot) is **refuted on this machine**: release is faster (best 1.9 s vs dev ~2.0-4.5 s
wall) but does not clear 500 ms.

Typed residual: cold-boot floor is dominated by erts/beam boot + code load, not mix —
further cuts require AOT/disk-cache levers (beam strip-uncompressed, BINDIR-relative code
path trimming, or a deferred-listener start phase), not config.

## Warm restart: typed FAIL (defect, not a timing miss)

`bin/smalt restart` (RPC `System.restart()`) reproducibly **terminates the node without
rebinding any listener** (observed twice in-lane: 85.5 s hang, `rebind_ok=0`,
`errors=1` row; node log ends at the `ETS-TRANSFER` shutdown line — init restart begins
but the VM exits before re-running the supervision tree). One early manual run DID rebind
(1.66 s) — the behavior is racy, majority-fail. Warm recovery is currently only via
stop→start cycle (2.7–3.6 s). Candidate root cause: `System.restart/0` inside a release
whose `start` wrapper is not restartable — typed as a real release defect, filed here.

## Functional serve receipts (post-boot, anonymous mode, release build)

- ARM: `GET http://127.0.0.1:39950/subscriptions?api-version=2020-01-01` → **200**
  `{"value":[{"displayName":"Sovereign Smalt Subscription",...,"state":"Enabled"}]}`
- Cosmos: `GET http://127.0.0.1:39952/dbs` (x-ms-version 2019-08-01) → **200**
  `{"Databases":[],"_count":0}`
- (`/` on ARM is 404 — no root route; not a health-endpoint failure, the op-level probes above are the receipt.)

## Supersession

This receipt **supersedes t45 BOOTPROF's dev-path numbers for the NFR-FOOTPRINT
cold-start cell**: the ceiling governs production builds; the dev profile (1.25–2.4 s
pre-eval) is retained as diagnostic only. BOOTPROF's Proposal 1 ("prebuilt release boot,
est. −800 to −1500 ms") is witnessed but lands short of the ceiling — remaining gap ~1.4 s
at best.

## Limitations (honest)

- Machine was heavily loaded by other lanes during the final run (cold walls 11.9–28 s vs
  1.9–4.5 s quiet); both series reported, verdict uses the quiet series (conservative
  FOR the ceiling).
- `warm_stop_start_cycle` rows mislabeled `warm-cycle-1` twice in the raw emit; corrected
  in the result file post-run (row content unchanged).
- `smalt eval` boot of the same release is 0.31 s total — evidence the wrapper/VM cost is
  small and the cold-boot floor is in app/code-load phases, consistent with the typed
  residual above.
- Warm-restart defect observed under this release layout only; no cross-check against a
  minimal release was run (out of lane scope).
