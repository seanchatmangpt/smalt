# ENVELOPE_RESET

The v26.10.19 envelope reset: the repo is wrapped in a four-layer
boundary envelope (Automation / Hermetic / IaC / Orchestration). Each
layer gets a fail-closed gate script under `scripts/envelope/`, an
aggregate recipe in `justfile.d/35-envelope.just`, and a non-vacuity
court before the layer is declared LANDED. Status vocabulary: LANDED
(script on disk, executed against the tree), PENDING (not landed),
REFUSING (landed and correctly failing against current violations).

## Four-layer mandate (ARD)

1. **Automation** — every executable script/recipe runs supervised,
   portable, and honestly: no coordination sleeps without a
   `# SLEEP-CLASS:` annotation, no unmanaged spawns (nohup/setsid/disown,
   backgrounded mix/beam/node without the `9>&-` lock-fd guard), no
   hardcoded `/Users/` paths, no references to retired test trees on
   executable lines, no unfalsifiable success echoes.
2. **Hermetic** — the container subject is `docker/Dockerfile.hermetic`:
   final stage does no package-manager installs (ca-certificates-only
   allowlist), runs as non-root, copies no credentials, no `:latest`
   base, no remote-URL ADD, carries a HEALTHCHECK, and pins its subject
   via 40-hex `ARG SUBJECT_SHA`.
3. **IaC** — infrastructure definitions are pinned and statically
   checked the same way (gate: `scripts/envelope/iac_gate.py`).
4. **Orchestration** — boot/ordering surfaces derive from the boot
   library, never ad hoc (gate: `scripts/envelope/orchestration_gate.py`).

## Phase 0-4 status (as of 2026-10-19, read from disk)

| Phase | Layer | Status | Evidence |
|---|---|---|---|
| 0 | Audit corpus | LANDED | automation: 29 viol / 164 files; container: 1 REFUSE |
| 1 | Automation gate | LANDED (REFUSING) | `automation_gate.py`, 5 classes, `--self-test` PASS |
| 1 | Container gate | LANDED (REFUSING) | `container_gate.py`, 8 poisoned fixtures |
| 1 | IaC gate | LANDED (REFUSING) | `iac_gate.py`, self-test x0; run: 1 viol, x1 |
| 1 | Orch. gate | LANDED (REFUSING) | `orchestration_gate.py`, st x0; run: 11 viol, x1 |
| 1 | leak detector | LANDED (PASSING) | `leak_detector.sh` on disk; `just leak-check` x0 |
| 1 | Envelope shim courts | PENDING | `envelope-gates-courts` reserved, typed exit 3 |
| 2 | Hermetic image build | PENDING | no `smalt:hermetic` image on daemon; runtime loud-skipped |
| 3 | IaC migration lanes | PENDING | gate landed; 1 tf-fixture violation open |
| 4 | Orchestration migration | PENDING | gate landed; 11 compose-healthcheck violations open |

## Forbidden -> mandated matrix (per the ARD)

| Surface | Forbidden | Mandated |
|---|---|---|
| scripts/, justfile.d/, burn/ | `sleep N` w/o `# SLEEP-CLASS:` | bounded polls / `send_after` |
| any spawn line | nohup/setsid/disown; bg spawn w/o fd guard | `9>&-` spawn; supervision restarts |
| path literals | `/Users/...` hardcoded | derive from repo root / `$HOME` |
| test refs | retired trees (test/sdk-, test/wire) on exec lines | fresh `test/internal/` set |
| hermetic final stage | pkg installs, root USER, cred COPY | ca-certs-only, non-root, check |
| success reporting | success echo, no exit discipline | typed exit 0/1/3; SKIP is loud |

## Acceptance gates (exact commands)

| # | Gate | Command | Standing |
|---|---|---|---|
| 1 | Automation layer | `just envelope-automation` | REFUSING: 29 viol — exit 1 until cleaned |
| 2 | Hermetic layer | `just envelope-container` | REFUSING: 1 static REFUSE — exit 1 until fixed |
| 3 | IaC + Orchestration | `just envelope-iac` / `-orchestration` | REFUSING: 1 + 11 viol — x1 |
| 4 | Aggregate + non-vacuity | `just envelope-gates` / `-courts` | exit 1; courts typed 3 |

Reset acceptance contract (5-gate, "100% replaced, not deleted"):
`python3 scripts/acceptance_gates.py` — exit 0 OK / 3 PENDING / 1 FAIL.

## See Also

`scripts/envelope/` · `justfile.d/35-envelope.just` ·
`docs/jira/v26.10.19/07-clean-room-reset.md` ·
`docs/NO_SLEEP_DOCTRINE.md`
