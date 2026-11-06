# Port Law

Every TCP port a smalt harness may bind is a member of exactly one family,
or is a reserved literal. The mechanical gate is
`scripts/port_registry_check.py` (`--check` fail-closed, `--report`
report-only, `--falsify` self-test). This doc is the prose twin of the
`FAMILIES` table inside the script — the script's table is ground truth.

## Families

| family | blocks | ports/block | formula | notes |
|---|---|---|---|---|
| front | front/canonical | 6 | fixed: amqp=5672 eh=5673 arm=9443 egress=8443 tls=9444 mcp=9545 | front door (`/tmp/smalt-substrate.lock`) |
| b | b1..b20 | 6 | 39000+10N..+5 | bench b-lanes |
| c | c1..c48 | 6 | 39200+10N..+5 | bench c-lanes; **c48 legacy-reserved** (do not re-issue) |
| v | v1..v29 | **7** | 39700+10N..+6 | 7th slot = kafka; **kafka is the v-face only** — front/b/c never bind kafka from `sb_block_ports` |
| reserved | — | — | 4566, 8085, 9099 | arcus-reserved literals, never claimable |
| UDS | — | — | — | UDS consumers need no TCP claim; the registry checks TCP only |

## Legacy-frozen blocks and literals

- **v14, v15** are LEGACY-FROZEN: they were the old default private blocks of
  `verification/ts/run-all.mjs` (v14) and `verification/ts/diagnostics.probe.mjs`
  (v15) in the 6-port era (39840-39845 / 39850-39855). Do not re-issue; new
  private blocks are v16 (diagnostics) and v17 (ts private/throttle). New v
  claims inside the v-family must use the 7-port law (+6 kafka slot).
- **c48** legacy-reserved (historic census artifact; never claimable).
- LEGACY literals: `39730-39735` (v3's 6-port prefix — v3 is now the py anon
  block, 7 ports 39730-39736), `39740-39745` (v4 prefix, py throttle),
  `39750-39755` (v5 prefix, py mesg). The 6-port prefix literals appear in
  `examples/fintech-throttle` comments; they name the same blocks (v3/v4/v5
  formula unchanged, only the +6 kafka slot is additive).

## LIVE_PICKS (current assignments)

| block | owner | use |
|---| -- |---|
| front | scripts/substrate.sh | canonical front door |
| v1 | verification/py/run.sh + conftest enforce fallback | py enforce shared |
| v3/v4/v5 | verification/py/conftest.py (anon/throttle/mesg) | py private faces |
| v13 | verification/ts/run-all.mjs shared block | ts shared substrate |
| v16 | verification/ts/diagnostics.probe.mjs | diagnostics private |
| v17 | verification/ts/run-all.mjs private block | ts throttle profile (wf5) |
| b1..b5, c1..c10 | scripts/bench lanes | bench windows |
| — | arcus | 4566 / 8085 / 9099 reserved, never claim |

## Live-picks census (--report / --check)

`port_registry_check.py --report` scans `lsof` LISTENers on the loopback and
classifies every port: lawful family member, reserved literal, frozen-block
member, or unregistered. `--check` is the same census fail-closed: any
listener outside all families, on a frozen block, or on a reserved literal is
a violation (exit 1). Report mode always exits 0 and lists findings.
