# BK-CLIV: final consolidated smalt-cli verify (post 5-wave repair surface)

**Standing: ALIVE** · Context: solo · 2026-10-22 · Lane BK-CLIV (read-only verify; only this receipt written)

Subject: fully-merged tree at verify time (HEAD daea2d87 lineage). Final
consolidated verification of the smalt-cli surface after the five repair
waves (EXPL12-R/C/D/W + EXPL12-B), exercising the cross-lane interplay on a
real substrate.

## 1. Full py harness (real lane-private substrates, SMALT_CLI_LANE=bkcliv)

Verbatim result lines:

```
tests/      (all, no -m): 149 passed, 2 skipped, 6 warnings in 118.68s
tests/ -m anonymous:       37 passed, 114 deselected in 29.69s
tests/ -m enforce:         35 passed, 2 skipped, 114 deselected, 6 warnings in 59.68s
smalt_cli/ (package lanes): 102 passed, 6 warnings in 368.82s
```

The harness self-booted lane-private anonymous (port 39620) and enforce
(39560/39561) substrates (boot markers `/tmp/smalt-cli-sub-bkcliv-{anonymous,enforce}-*.boot.json`);
both tore down cleanly with the sessions — no lease left behind,
`smalt-cli/_build-lane-cli` absent at close.

## 2. Cross-lane interplay — end-to-end on the live shared substrate
(:enforce, pid 81426, ARM http://127.0.0.1:9443, egress http://127.0.0.1:8443)

One session, profile-resolved endpoints throughout (env unset after login;
precedence env > profile > defaults exercised by profile fallback):

```
$ login --arm http://127.0.0.1:9443 --egress http://127.0.0.1:8443 \
    --client-id bkcliv --client-secret bkcliv-local -o json
{ "verified": true, "profile": "/tmp/bkcliv-profile.json", "arm": "...:9443",
  "egress": "...:8443", "amqp": "127.0.0.1:5672",
  "tenant": "00000000-0000-0000-0000-000000000000",
  "token_type": "Bearer", "expires_in": 3600 }        exit=0   (0600 file)

$ storage container-create clivc1792678356 --immutable -o json
{ "container": "clivc1792678356", "status": 201, "immutable": true,
  "etag": "\"0x400E5AD0F018C047\"" }                  exit=0
$ storage container-create clivc1792678356 --immutable -o json   # replay
ANDON container-create clivc1792678356 (HTTP 409)    exit=1   (typed ANDON)

$ servicebus topic-create -n clivt1792678363 -o json
{ "topic": "clivt1792678363", "namespace": "cli-ns", "status": 201 }  exit=0
$ servicebus subscription-create --topic-name clivt1792678363 -n clivs -o json
{ "subscription": "clivs", "topic": "clivt1792678363",
  "namespace": "cli-ns", "status": 201 }              exit=0

$ monitor endpoints -o json        -> full discovery envelope, exit=0
$ monitor metrics cli-rg smalt.servicebus topics clivt1792678363 -o json
{ "resource": ".../topics/clivt1792678363", "series_count": 0, "value": [] } exit=0
$ monitor ocel-tail -n 3 -o json   -> real OCEL events array, exit=0
```

Every face exercised rides its landed wave: login/profile persistence
(EXPL12-B), `--immutable` WORM opt-in + 409 conflict ANDON (EXPL12-R),
`-n` az-parity flag reshape (EXPL12-C/D), `arm_request` tokenless→STS→bearer
handshake under the metrics/endpoints calls (EXPL12-W). One operator error
during the run (extra positional to `monitor metrics`) was a usage error,
not a defect — retried with the 4-positional signature, 200.

## 3. Pyright at HEAD — all previously flagged diagnostics RESOLVED

`pyright 1.1.409` over `smalt_cli/wire.py`, `profile.py`, `config.py`,
`commands/login.py`, `commands/monitor.py`, `commands/servicebus.py`,
`commands/storage.py`:

```
0 errors, 0 warnings, 0 informations
```

(wire.py imports, monitor.py tail_lines, login/profile imports — none flagged.)

## 4. Standing

ALIVE — the post-wave surface is coherent end to end: suites green in both
auth sessions, the five waves compose on one real substrate session without
typed refusals other than the intended 409 WORM ANDON, and static analysis
is clean at HEAD.
