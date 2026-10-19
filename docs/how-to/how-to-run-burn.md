# how to run the burn suite

Saturation burn: prove the substrate survives degraded-host CPU hogs, an
AMQP atom-flood, containerized boot/chaos cycles, and a fully gated burn
ring — under one image digest bound to one subject SHA.

By the end you will have run a host soak, the 4-container matrix, and know
how to gate-validate the tracked JSONL receipts.

## What you need

- Docker (for `burn-matrix`/`burn-boot`/`burn-ring`); the host soak runs
  without docker.
- The `smalt:local` image (matrix/boot legs boot it). Free AMQP port 5672
  for the soak flood (override `SMALT_BURN_AMQP_PORT`).
- Recipes live in `justfile.d/30-burn.just` (addendum: they are NOT in
  `docs/JUST_REFERENCE.md` yet — d2 audit gap).

## The lanes

| recipe | runs | exit |
|---|---|---|
| `just burn-soak` | host soak (`docker/burn/soak.sh`): 4x `yes` CPU hogs + AMQP atom-flood + offline suite + wire tier x rounds; rows in `tmp/burn-soak-<ts>.jsonl` | 0 clean / 1 burn failure / 3 usage or preflight |
| `just burn-chaos` | same at `--hogs 8 --rounds 1` (degraded-host hammer class) | same |
| `just burn-matrix` | 4-container parallel compose matrix (`docker/burn/parallel-matrix.sh`); asserts N/N clean, zero published host ports | 0 clean / 1 not all-clean / 2 preflight refusal (HOST_PORT_PUBLISH_REFUSED) / 3 usage |
| `just burn-boot` | boot burn x50 per plane inside containers (`docker/burn/boot-burn.sh`); jidoka on first typed violation | non-zero on first typed row |
| `just burn-ring` | AZB-22 ring: boot x50 → chaos x50 → matrix (N=8) → soak on ONE image digest bound to ONE subject SHA | non-zero on any stage |
| `just burn-clean` | lane roots + burn volumes + `docker/burn/results` reclaim | — |
| `just burn-ocel` | projects tracked burn rows to OCEL 2.0 + validates | non-zero on invalid |

Extra args forward: `just burn-soak --dry-run`.

## Step 1: host soak (no docker)

```bash
just burn-soak --rounds 1
```

The soak writes JSONL rows classifying every failure against
`docs/jira/v26.10.17/FLAKE_LEDGER.md`: only UNLEDGERED failures fail the
burn; ledgered faces are recorded, not fatal. Every wait is a bounded
deadline poll — no fixed sleeps (no-sleep doctrine).

## Step 2: container matrix

```bash
just burn-matrix
```

Preflight anti-vacuity: `docker compose config` on the burn project must
show ZERO published host ports; any `published:` key refuses with exit 2
before a container runs. Per-container probes run in per-container netns;
the driver asserts the host side is empty after a green run.

## Step 3: the burn ring

```bash
just burn-ring --stage boot    # boot|chaos|matrix|soak|summary, individually resumable
just burn-ring
```

The ring records `SUBJECT_SHA` at init; the summary stage re-reads
`git rev-parse HEAD` and refuses with `R_missing_identity` if the subject
moved — a commit landed after ring start can never mint a green summary.
Rows land in `docs/jira/v26.10.18/burn/ring-<run-id>/` (tracked, never
`tmp/`).

## Step 4: gate-validate the receipts

```bash
python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/boot-burn.jsonl
```

`--gate` checks every declared (container, cycle, stage) cell against the
`run_header` expected matrix — a dropped cycle is a loud `MISSING_CELL`,
never a silent skip. Exit 0 valid / 1 schema violation, MISSING_CELL,
DIRTY_ROW / 2 usage.

## Verdict vocabulary

Rows use schema `smalt-burn/v2`; verdicts and the `broken_term` coupling law
are normative in `docs/reference/burn-receipt-schema.md`.

## See Also

- `docs/reference/burn-receipt-schema.md` (row schema, normative)
- `justfile.d/30-burn.just` (recipes)
- `docs/jira/v26.10.18/burn/README.md` (tracked rows)
- `docs/jira/v26.10.18/receipts/azb-22-burn-ring.md` (ring receipt)
