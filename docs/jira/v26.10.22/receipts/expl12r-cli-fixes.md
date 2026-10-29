# EXPL12-R: smalt-cli flag-parity repairs (EXPL12-1/2/4)

Standing: ALIVE · Context: solo · 2026-10-22 · Lane EXPL12-R

Repairs EXPL-12's top three tickets (source receipt:
`docs/jira/v26.10.22/receipts/expl12-cli-flag-parity.md`). Files touched:
`smalt-cli/smalt_cli/commands/storage.py`, `smalt-cli/smalt_cli/commands/deployment.py`,
`smalt-cli/tests/test_ty_storage.py`, `smalt-cli/tests/test_ty_deployment.py`.
servicebus.py untouched (EXPL12-3 not in this lane's scope; ty_servicebus stays green).

## EXPL12-1 (P0): storage `--immutable` silent no-op — FIXED

`storage.py` now builds its own container headers (no longer the stale
`wire.container_put_headers`): `--immutable` sends `x-ms-immutable-policy: true`
(the KD-135 opt-in WORM shape, egress_router.ex:1418); `--no-immutable` sends
the explicit-false form; default flag value is `--no-immutable` (writable
default). Help text de-rotted (post-KD-135 truth: writable default, opt-in WORM).

## EXPL12-2 (P1): storage group KD-15 challenge handshake — FIXED

New `storage._blob_request` helper: tokenless first touch takes the 401, then
one bearer retry via `wire.bearer_for_arm()` (same contract as
`wire.kv_request`/`cosmos_request`). All three storage commands
(container-create / container-list / blob-upload) route through it.

## EXPL12-4 (P1): deployment `-p/--parameters` — FIXED

`deployment.py` adds repeatable `--parameters/-p` accepting `@file.json`,
`.json` file path, inline JSON object, or `KEY=VALUE` pairs; merged into the
deployment body's `parameters` (absent -> `{}`, az default). ARM expression
substitution `[parameters('k')]` (single/double quotes) resolves recursively
over resource bodies AND resource names before materialization; unknown names
left verbatim.

## Falsifiers (real wire, embedded)

`smalt-cli/.venv-cli/bin/python -m pytest tests/test_ty_storage.py -q -p no:cacheprovider`
(anonymous substrate, lane-private ports):

```
.....                                                                    [100%]
5 passed in 25.20s
```

New legs: `test_immutable_container_rejects_overwrite_409` (--immutable create
201 -> first upload 201 -> overwrite ANDON exit 1, the 409 WORM refusal) and
`test_default_container_stays_writable` (no-flag create -> two uploads 201).

`smalt-cli/.venv-cli/bin/python -m pytest tests/test_ty_deployment.py
tests/test_ty_servicebus.py -q -p no:cacheprovider` (:enforce substrate):

```
.....                                                                    [100%]
5 passed in 21.56s
```

New legs: `test_storage_kd15_challenge_handshake_on_enforce` (bare
container-create against :enforce succeeds after the handshake; raw tokenless
PUT probe asserts the 401 challenge leg is live) and
`test_deployment_parameters_file_materializes_value` (template with
`[parameters('lockDuration')]`/`[parameters('maxSize')]` + `--parameters
params.json` -> raw ARM GET proves the deployed queue carries
`lockDuration=PT5M`, `maxSizeInMegabytes=2048`, not the expression).

## Honest notes

- First two enforce-suite runs failed on MY test's own defects (template
  missing the parent namespace resource; bearer passed as body in the GET) —
  fixed in the test, not the code under test; final run is the receipt.
- An intermediate mangled write of storage.py (syntax error) was caught by the
  compile check before any suite run and rewritten.
- Substitution is lenient (unknown parameter names left verbatim) — the
  emulator face does not template-validate like real ARM; named divergence,
  not silent.
