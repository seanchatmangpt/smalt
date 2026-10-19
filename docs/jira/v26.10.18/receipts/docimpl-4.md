# docimpl-4 — D12/D13/D14 docs-audit implementation receipt

Standing: ALIVE
Date: 2026-10-18
Subject: smalt @ 05f5a9b (edits landed on disk; concurrent coordinator lanes
swept most of them into commits 756e806 / 05f5a9b; `workspace/ARCHITECTURE.md`
still carries the D12 edits uncommitted at receipt time — coordinator owns git).
Audit inputs: `docs/jira/v26.10.18/docs-audit/d14-docker-burn.md`,
`d13-cli.md`, `d12-workspace.md`.

## D14 — docker / burn

| Finding | Fix | File |
|---|---|---|
| BUILD_RECEIPT.md:6-13 build contexts missing ash_graphlaw/ggen_igniter | both build commands now pass all three `--build-context` flags (ash_r2rml + ash_graphlaw + ggen_igniter), matching the Dockerfile's COPY --from seam (docker/Dockerfile:52-57) | `docker/BUILD_RECEIPT.md` |
| README.md:15-25 wrong sibling set (ex4pm hex) | sibling set is now ash_graphlaw/ggen_igniter/ash_r2rml; ex4pm noted as hex-resolved since 26.10.14; "Mix validates all three declared paths at deps.get" rationale added | `docker/README.md` |
| compose.smalt.yml:14-17 missing ash_r2rml | `additional_contexts` now ash_graphlaw/ggen_igniter/ash_r2rml (paths ../../ — relative to docker/), header comment updated | `docker/compose.smalt.yml` |
| README HEALTHCHECK claim | reworded: healthcheck is compose-only (`healthcheck:` block); the image carries no HEALTHCHECK instruction; bare docker run reports no health state | `docker/README.md` |
| README:98-101 stale census snapshot ("as of 2026-10-14 ... 0/8") | replaced with a register pointer: `just sdk-census` + generated SDK_MATRIX.md are live truth; no dated pass counts in prose | `docker/README.md` |
| REGISTRY.md:94 v1→v2 | `smalt-burn/v1` → `smalt-burn/v2` (schema const is v2: burn-row.schema.json:26) | `scripts/bench/REGISTRY.md` |
| chaos-kill.sh:25-28 superseded gates-skip header | header now describes the real split: host mode (SMALT_GATES_HOST=1) runs the 6 gates; in-image standalone runs 4 scenarios and exits 0; BURN_GATES_UNAVAILABLE_IN_IMAGE rc=3 path documented as superseded. Also fixed stale "smalt-burn/v1" skip string at :109. Exit contract line updated. | `docker/burn/chaos-kill.sh` |
| parallel-matrix.sh:9 N=4 vs checked-in N=8 | doc comment now says default N=8; the code default was also aligned `REPLICAS=4`→`REPLICAS=8` (checked-in compose.burn.yml carries 8 `smalt-burn-all-*` services: 16 mentions / 2 per service) | `docker/burn/parallel-matrix.sh` |
| boot-burn/burn-ring stage-matrix mismatch | burn-ring.sh `stage_summary` expected matrix for `ring-boot` changed `["probe","recover","teardown"]` → `["boot","probe","teardown"]`: the emitter (boot-burn.sh:125 header + :329 recover-every-10th) is the contract; the gate only checks MISSING_CELL/DIRTY_ROW so the extra recover rows stay legal | `docker/burn/burn-ring.sh` |

Court (old-vs-new expected matrix against the real gate, synthetic CLEAN rows
for ring-boot cycle 1 — emitter declares boot/probe/teardown, so the old
declaration can never go green):

```
old.jsonl: exit=1
[VALIDATE-BURN] /tmp/burnring-court/old.jsonl: MISSING_CELL container=ring-boot cycle=1 stage=recover
new.jsonl: exit=0
[VALIDATE-BURN] /tmp/burnring-court/new.jsonl: OK
```

Syntax + compose resolution (real exits):

```
$ bash -n docker/burn/{chaos-kill,parallel-matrix,burn-ring}.sh   # SYNTAX-OK
$ docker compose -f docker/compose.smalt.yml config --quiet       # exit=0
```

## D13 — smalt-cli

| Finding | Fix | File |
|---|---|---|
| .venv → .venv-cli (:11-13, :72-73) | Install block uses `.venv-cli`; note added: single-interpreter ADR-PY-002 documented fallback, bare `.venv` never created; Verify block commands use `.venv-cli/bin/python` | `smalt-cli/README.md` |
| retired `gate VERB URL` (:45) | Commands list now documents the real `gate` sub-app (sdk-wire-conformance / hil-attestation / zero-actuation / audit-integrity per gates.py:636-658); `gate VERB URL` named as retired and superseded by `gate zero-actuation` | `smalt-cli/README.md` |
| scaffold-only daemon/audit (:43-44) | daemon/audit/test marked as scaffold echoes ("lane not landed"); hw documented as real-or-scaffold by typer availability | `smalt-cli/README.md` |
| test-layout (:59-60) | Tests bullet: SDK wire suites flat in `tests/test_*.py` (the real layout; historical `tests/sdk_wire/**` globs never existed) + package lanes co-located `smalt_cli/test_*.py` | `smalt-cli/README.md` |
| GATES.md :28/:123 ".venvs does not exist" | both passages now say the `.venvs/` directory exists but is EMPTY (symlinks deleted 2026-10-17, no per-lane venv lives there); fallback + venv_note wording preserved | `smalt-cli/GATES.md` |

## D12 — workspace

| Finding | Fix | File |
|---|---|---|
| README:16-19 layout omits src/lib/airgap-fetch.ts + middleware.ts | layout block adds `src/lib/airgap-fetch.ts` (server air-gap), `src/lib/azure/`, `middleware.ts` | `workspace/README.md` |
| :40-41 endpoints missing 9444 TLS twin | 9444 TLS twin added to the endpoint list (AIRGAP_ALLOWED_PORTS = 9443/9444/8443 per src/lib/airgap-fetch.ts:17) | `workspace/README.md` |
| :43-49 lint-rule list understates config | three-layer enforcement framing (client / server / lint); banned import group extended (superagent, ky, ws*); template-literal-URL ban listed; runtime loopback+port law named for both wrappers | `workspace/README.md` |
| :97-103 Commands missing e2e-court | Commands section adds e2e-court (`just ws-court` / node invocation) and describes the unit-import sweep + targeted checks + tsc + live-probe contract | `workspace/README.md` |
| ARCHITECTURE:8-10 missing :9444 | Context paragraph + containers diagram both carry `TLS twin :9444 (SDKs)` | `workspace/ARCHITECTURE.md` |
| :13-17 enforcement layers 2→3+ | zero-actuation/air-gap paragraph rewritten as three layers: client smaltFetch/assertLocalUrl, server airgapFetch+middleware (ports 9443/9444/8443), copilot verb-gate/ledger | `workspace/ARCHITECTURE.md` |
| :114-120 stale court verdict | refreshed against a real run this session: | `workspace/ARCHITECTURE.md` |

Fresh court run (this session, real output):

```
# court verdict
# PASS=51 FAIL=0 SKIP=1
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node
```

## Gates

```
$ just docs-dod-check   # exit=0 (full OK listing in session log)
```

## Disclosures

- Concurrent docimpl lanes committed portions of this wave's files mid-session
  (756e806 "docimpl wave part 1", 05f5a9b "docimpl-9 crosslinks batch-1"
  swept in-flight docker/smalt-cli/REGISTRY edits); per the no-git instruction
  this lane committed nothing. `workspace/ARCHITECTURE.md` was uncommitted at
  receipt time.
- The parallel-matrix.sh change includes one code-line alignment (default
  `REPLICAS=8`) beyond pure prose — required to make the corrected comment
  true; the ring driver passes `--replicas` explicitly either way.
- Docker image not rebuilt this session; build-context fixes verified by
  `docker compose config` resolution + Dockerfile COPY --from seam match, not
  by a fresh build.
