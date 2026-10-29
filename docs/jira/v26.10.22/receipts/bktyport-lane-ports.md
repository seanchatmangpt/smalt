# BK-TYPORT — ty/w3 enforce AMQP de-pinned from 38672

**Standing: ALIVE** — two enforce groups ran CONCURRENTLY, each green on its
own lane-private block, with a 2-second `lsof` census of 38672 across the
whole run returning **zero listener rows** (the old contention port was never
touched by either lane). `Context: solo`

## Subject

- Repo: /Users/sac/smalt @ main; lane BK-TYPORT.
- Files: `smalt-cli/tests/conftest.py` (5-line block swap, disclosed below),
  `smalt-cli/tests/test_ty_servicebus.py` (1 line),
  `smalt-cli/tests/test_ty_deployment.py` (1 line);
  `test_w3_session_ops.py` needed ZERO edits (conftest already seeds
  `W3_AMQP_PORT`).

## Typed residual closed (from bkconf-private-ports.md)

BK-CONF left the residual: ty/w3 enforce tests hardcoded
`127.0.0.1:38672`. Root cause was actually TWO layers:

1. The ty test files set `SMALT_AMQP=127.0.0.1:38672` literally —
   fixed by the 1-line edits reading `conftest._ENF_AMQP_P`.
2. **conftest itself re-pinned `_ENF_AMQP_P`**: line 441 read
   `os.environ.get("CLI5_AMQP_PORT", "38672")`, overriding the derived
   block's +2/+3 ports. So even with (1) fixed, both concurrent enforce
   substrates still booted AMQP on 38672 — witnessed: first concurrent run,
   c1 booted on 39940 and c2's substrate died
   `{:listen_failed, 38672, :eaddrinuse}` -> 7 loud skips (exit 0).

Layer (2) required a minimal edit to conftest.py (BK-CONF's landed lane
file) — applied under the compile-freeze/disclosure law: the enforce
amqp/eh now derive from `_ENF_BLOCK["ports"][2]/[3]` with
`CLI5_AMQP_PORT`/`CLI5_EH_PORT` seeded via `setdefault` before collection
(explicit overrides still win). This also fixes `test_servicebus.py` /
`test_eventhub.py` module-level reads, which read the same env vars.

## Proof (embedded concurrent-run output)

Two groups launched simultaneously (~0.5 s apart), real substrate boots per
group (markers: pids 87210 on block 39940, 87209 on block 39990 — distinct
relocated blocks), teardown clean:

```
$ SMALT_CLI_LANE=bktyport-c1 .venv-cli/bin/python -m pytest tests/test_ty_servicebus.py tests/test_ty_deployment.py tests/test_w3_session_ops.py -q
6 passed, 1 skipped in 27.21s
C1-EXIT=0

$ SMALT_CLI_LANE=bktyport-c2 ... same, concurrent ...
6 passed, 1 skipped in 27.69s
C2-EXIT=0
```

Contention witness: 30 samples at 2 s intervals of
`lsof -nP -iTCP:38672 -sTCP:LISTEN` during the concurrent run:

```
38672 listener rows during run: 0   (file /tmp/bktyport-38672.lsof)
```

Before the conftest fix the same witness showed c2's boot log ending in
`{:listen_failed, 38672, :eaddrinuse}` — the falsifier flipped AFTER the
fix, not before (both runs witnessed, receipts above).

Single-lane pre-run (`bktyport-t1`): 6 passed, 1 skipped, exit 0. The 1
skip per group is the registered KD-21/KD-77 AMQP wire-divergence loud
skip (expected, not a port failure — it appeared in BK-CONF's runs too).

## Regression

Full cli suite, single invocation, new conftest:

```
$ SMALT_CLI_LANE=bktyport-reg .venv-cli/bin/python -m pytest tests/ -q
1 failed, 128 passed, 2 skipped, 6 warnings in 66.41s
```

The single failure is `test_error_codes_doc.py::
test_error_codes_doc_is_byte_identical_projection` — pre-existing
`docs/ERROR_CODES.md` drift from concurrent lib/ edits on the shared
checkout (reproduces in isolation via `pytest tests/test_error_codes_doc.py`;
documented in bkconf-private-ports.md as the same pre-existing class, regen
left to the coordinator). 128 passed is +9 over BK-CONF's run (their run
deselected differently); no substrate-riding test regressed.

## Falsifier status

- Falsified-defect check: with the pin, two concurrent enforce groups
  contended on 38672 (witnessed `:eaddrinuse` + 7 skips). After the fix,
  same experiment yields distinct blocks (39940/39990), both green, zero
  38672 listeners — the defect did not reproduce.
- No new GAP tokens, no KD rows minted; the KD-21/KD-77 skip path is
  unchanged and still fires (1 per group).
