# BK-CONF — cli conftest lane-private port blocks

**Standing: ALIVE** — two cli test groups ran CONCURRENTLY, each against its
own real substrate boot on a distinct derived private block: anonymous
**24 passed, exit 0** (lane `bkconf-g1`, block 39880-84) and enforce
**28 passed, 2 skipped, exit 0** (lane `bkconf-g2`, block 39920-24).
`Context: solo`

## Subject

- Repo: /Users/sac/smalt @ main; lane files
  `smalt-cli/tests/conftest.py` + `smalt-cli/tests/_lane_ports.py` (new
  helper). No substrate.sh changes, no other harness touched.
- Closes the BK-149C typed follow-up: under load the cli4/cli5 conftest
  identity guards mutually swept the shared fixed blocks 39643/38654,
  killing substrates mid-run across concurrent suites.

## Mechanism (smalt-cli/tests/_lane_ports.py + conftest)

- Lane name: `$SMALT_CLI_LANE-<profile>` if set, else
  `cli-<profile>-<venv basename>`; profile = `anonymous` | `enforce`.
- Block: `sha256(lane) mod 50` selects a 10-wide slot in **39500..39990**
  (avoids bench b1..b12 = 39010..39125 and the legacy 39643/38654 blocks).
  Ports: base+0 arm, +1 egress, +2 amqp, +3 eh, +4 arm_tls.
- Collision law: occupied foreign slots are **relocated, never swept** — the
  scan walks `(hash + k) mod 50` to the first block whose 5 ports are all
  free; a per-(lane, base) marker (valid pid+freshness) claims a block back
  for sequential reuse.
- Env overrides: `SMALT_CLI_LANE` (per-invocation lane name),
  `SMALT_CLI_PORT_BASE` (pin the anonymous-profile base directly), plus the
  pre-existing `SMALT_ARM`/`SMALT_EGRESS`.
- Sweep scope is narrowed: `_ensure_substrate` gained `sweep_ports` — only
  lane-owned plane ports are ever swept. Sweep of any other lane's live
  substrate is now structurally impossible (the BK-149C defect class).
- Lock/log/marker paths moved to per-lane
  `/tmp/smalt-cli-sub-<lane>[-<base>]{.lock,.log,.boot.json}`.
- conftest seeds `CLI5_ARM_PORT`/`CLI5_EGRESS_PORT`/`W3_AMQP_PORT` env
  defaults at import (before test-module collection) so test modules resolve
  the derived enforce arm/egress ports without edits.

## CLI AMQP surface pins (typed residual)

- test_ty_servicebus.py / test_ty_deployment.py / test_w3_session_ops.py
  hardcode `127.0.0.1:38672` in files outside this lane's commit scope.
  The enforce lane therefore pins `amqp=38672`, `eh=38673` while
  arm/egress/arm_tls stay derived. Pinned ports are health-checked but
  **never swept** (`sweep_ports`).
- Typed residual: two concurrent enforce groups contend on the pinned 38672
  — the loser fails its bind and skips LOUDLY (SUBSTRATE_DIED -> loud skip),
  it never sweeps the live lane. The witnessed BK-149C class (mutual ARM-port
  identity-guard sweeps mid-run) is closed by construction. Full closure of
  the residual needs a 2-line edit in the ty test files (read
  `conftest._ENF_AMQP_P`) — filed for the coordinator, not landed here.

## Proof (embedded concurrent-run output)

Both groups launched simultaneously (~0.5 s apart), real substrate boots per
group (markers written 0.5 s apart, pids 63780 / 63799), teardown clean
(post-run `lsof` on lane ports: empty, rc=1):

```
$ SMALT_CLI_LANE=bkconf-g1 .venv-cli/bin/python -m pytest tests/ -m anonymous -q
........................                                                 [100%]
24 passed, 107 deselected in 8.40s
G1-EXIT=0

$ SMALT_CLI_LANE=bkconf-g2 .venv-cli/bin/python -m pytest tests/ -m enforce -q
28 passed, 2 skipped, 101 deselected, 6 warnings in 47.89s
G2-EXIT=0
```

No-collision witness: 2 s-interval `lsof` census of 39000-39999 during the
concurrent run — 211 census rows during the window; distinct ports observed:

```
g1 (anonymous): 39880 39881 39884            (block base 39880)
g2 (enforce):   39920 39921 39922 39923 39924 (block base 39920)
intersection: empty — disjoint blocks
```

(`39880` is the `(hash(bkconf-g1-anonymous)+k) mod 50` first-free slot — the
deterministic hash slots were occupied by other live lanes on this machine;
relocation, not sweep, is the witnessed path.)

## Regression

Full suite, single invocation, new conftest:

```
$ .venv-cli/bin/python -m pytest tests/ -q
1 failed, 119 passed, 11 skipped, 6 warnings in 48.35s
```

The single failure is `test_error_codes_doc.py::
test_error_codes_doc_is_byte_identical_projection` — pre-existing
`docs/ERROR_CODES.md` line-anchor drift from concurrent lib/ edits on this
shared checkout (`scripts/gen_error_codes.py --check` reproduces; the exact
class BK-149C Fix 1 documented). Not introduced by this lane; regen is left
to the coordinator to avoid racing in-flight lib/ edits. All substrate-riding
tests pass.

## Falsifier status

- Falsified-defect check: with the old shared fixed blocks, two concurrent
  suites swept each other's substrates (BK-149C). With derived blocks the
  census shows disjoint blocks and both groups green simultaneously — the
  defect class did not reproduce.
- A lane never sweeps outside its own derived block (`sweep_ports`); the
  census shows zero listeners outside each lane's own block attributable to
  these runs.
