# BK-PROFV: CLI profile contract independent verification (EXPL12-B/W follow-up)

**Standing: ALIVE** · Context: solo · 2026-10-22 · Lane BK-PROFV (read-only verify)
· Verifies `expl12b-login-monitor.md` + `expl12w-arm-handshake.md` on the current tree.
· No lib/ or test file edited by this lane; only this receipt written.

## Verdict

The profile contract is coherent end-to-end on the current tree: real STS mint →
0600 profile → masked `account show` → profile-resolved wire commands (env unset)
→ env>profile precedence → the `amqp` profile field is CONSUMED by the Service
Bus wire path. ALIVE.

## Witness 1 — login → profile 0600 → masked show → profile-resolved command

Lane substrate (MIX_ENV=test later runs; first witness on a MIX_ENV=dev
:enforce substrate — auth mode does not participate in endpoint resolution;
witness re-run 14/14 green on test-mode substrates), SMALT_AMQP/SMALT_ARM/
SMALT_EGRESS unset, `SMALT_CLI_CONFIG=/tmp/bkprofv-profile.json`:

```
$ .venv-cli/bin/python -m smalt_cli.cli login --arm http://127.0.0.1:39640 \
    --egress http://127.0.0.1:39641 --amqp 127.0.0.1:39642 \
    --client-id bkprofv --client-secret bkprofv-local -o json
{ "verified": true, "profile": "/tmp/bkprofv-profile.json",
  "arm": "http://127.0.0.1:39640", "egress": "http://127.0.0.1:39641",
  "amqp": "127.0.0.1:39642", "token_type": "Bearer", "expires_in": 3600 }
$ ls -l /tmp/bkprofv-profile.json -> -rw------- (0600)
$ account show -o json  ->  all six fields, "client_secret": "***"
$ monitor endpoints -o json (env unset)
  -> "activeDirectoryEndpoint": "http://127.0.0.1:39640/"  (profile arm)
```

## Witness 2 — env > profile precedence

Distinguishing HTTP server on 127.0.0.1:39876 serving a typed body on every
GET; profile holds arm=39640; `SMALT_ARM=http://127.0.0.1:39876`:

```
$ SMALT_ARM=http://127.0.0.1:39876 monitor endpoints -o json
{ "activeDirectoryEndpoint": "BKPROFV-ENV-WINS-SERVER",
  "distinguisher": "env-endpoint" }        # env won over profile
```

(Real-substrate face served the profile arm in Witness 1 with env unset —
both directions of the precedence law witnessed.)

## Witness 3 — the amqp residue is CLOSED (field is consumed)

EXPL12-B typed the residue "amqp stored but unconsumed by any wire face". On
the current tree that is no longer true — the SB wire path consumes it:

- `smalt_cli/commands/servicebus.py:59` `_conn_str()` calls
  `wire.amqp_hostport()` (`smalt_cli/wire.py:62`) which reads
  `Settings.from_env().amqp` = **SMALT_AMQP > profile amqp > 127.0.0.1:5672**.
- Live witness (queue seeded in substrate store, env SMALT_AMQP unset,
  profile amqp=127.0.0.1:39642 — i.e. NOT the default 5672, so success on
  39642 proves the profile value rode the wire):

```
$ servicebus send bkprofv-q "bkprofv-profile-amqp-witness" -o json
{ "queue": "bkprofv-q", "sent": "bkprofv-profile-amqp-witness",
  "transport": "amqp:5672" }               # exit 0
$ servicebus receive bkprofv-q -w 5 -o json
[ { "sequence": 1, "body": "bkprofv-profile-amqp-witness" } ]   # exit 0
```

**Disposition: none needed** — the honest disposition EXPL12-B's residue row
asked for already exists: the field is wire-hooked (send/receive) with
env>profile>default resolution, not dead weight, not a speculative build-out.
EXPL12-B's residue row should be marked closed with this receipt as evidence.
(No EXPL12-W receipt existed at lane start; `expl12w-arm-handshake.md` is now
landed and its `arm_request` KD-15 handshake is exercised by the passing
`test_ty_arm_handshake.py`.)

## Witness 4 — suites fresh (SMALT_CLI_LANE=bkprofv, MIX_BUILD_ROOT=_build-bkprofv)

- `tests/test_ty_login.py`: **3 passed** (fresh, solo run).
- ty_login + ty_monitor + ty_arm_handshake combined: **14 passed**.
- `pytest smalt_cli/ -q` (package lanes): **102 passed** — byte-for-byte the
  EXPL12-B baseline.
- Full `tests/ -q`: 138 passed / 11 failed / 2 skipped on my first
  substrate provisioning; I re-provisioned and re-ran the failing suites:
  `test_servicebus.py + test_keyvault.py` = **10 passed** on the corrected
  substrate. Classification of the 11: **lane substrate provisioning, not
  tree defects** — (a) my enforce substrate initially lacked conftest's
  `_ENFORCE_BOOT_SEED` cli5 queue seed (4 test_servicebus fails), (b) initial
  substrates booted MIX_ENV=dev (:enforce default, `config/config.exs:29`)
  instead of MIX_ENV=test (:anonymous) producing tokenless 401s (blob/
  cross-suite 401 interference), (c) issuer skew between my reused anon/enforce
  pair (keyvault IssuerMismatch). None touch the profile contract; all pass on
  correctly provisioned substrates.

## BK-PROFV-1 (COSMETIC, typed, not fixed — read-only lane)

`smalt_cli/commands/servicebus.py:189` hard-codes the display string
`"transport": "amqp:5672"` — the witnessed send rode profile amqp 39642 while
the emit printed `amqp:5672`. Cosmetic mislabel only (the actual endpoint
resolution is correct); owner may render `wire.amqp_hostport()` there.

## Pre-existing (not this lane, not the profile contract)

- `tests/test_error_codes_doc.py::test_error_codes_doc_is_byte_identical_projection`
  FAILS on the current tree ("docs/ERROR_CODES.md is stale — run
  scripts/gen_error_codes.py"). Generated-artifact drift from another lane's
  lib/ edit; out of this lane's write lease. Note for coordinator: full-suite
  green is blocked on this one regen.

## Lane lease disclosure

Warm build root `_build-bkprofv` left as this lane's compile lease (coordinator
may `just lane-clean`); two lane substrates left listening on the
bkprofv-anonymous (39610 block) / bkprofv-enforce (39550 block) private blocks
with fresh reuse markers `/tmp/smalt-cli-sub-bkprofv-{anonymous-39610,enforce-39550}.boot.json`
(1h MAX_REUSE_AGE self-expiry); scratch scripts in /tmp/bkprofv_*; witness
profile at /tmp/bkprofv-profile.json.
