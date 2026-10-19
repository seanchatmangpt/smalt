# burn lane — soak.sh + parallel-matrix.sh + 30-burn.just

Standing: PARTIAL_ALIVE — static + dry-run validation witnessed below; the
Context: solo(bash -n syntax + [BURN-SOAK][DRY-RUN] validation; no suite run)
live 3-round host soak and the 4/4 container matrix are not yet executed
(requires a quiet host and the `smalt:local` image; run `just burn-soak` /
`just burn-matrix` to close).

## Delivered

- `docker/burn/soak.sh` — host saturation burn: N x `yes` CPU hogs (default 4)
  + AMQP atom-flood generator (connect -> partial `PUT /flood HTTP/1.1` line ->
  mid-request close on 127.0.0.1:5672, reproducing the i22 `:closed`
  390-lines/ms logger-flood class,
  docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md) held across 3 rounds x
  (full offline suite + wire tier `--include amqp_wire`). `:stress` stays
  excluded per the v26.10.18 tier split (test/test_helper.exs). Failures are
  classified against docs/jira/v26.10.17/FLAKE_LEDGER.md (exact face match ->
  row standing
  CLOSED/OPEN-ROTATING; file-level match -> `<STANDING>-FILE`; no match ->
  UNLEDGERED, which fails the burn). JSONL rows
  (`smalt.burn-soak/1`: ts, round, tier, exit, tests, failures, faces,
  flood_conns, hogs) in `tmp/burn-soak-<ts>.jsonl`. Deadline polls everywhere,
  no fixed sleeps. Exit 0 clean / 1 burn failure / 3 usage. `--dry-run` prints
  the resolved plan and exits 0.
- `docker/burn/parallel-matrix.sh` — `docker compose -f docker/burn/compose.burn.yml
  up -d`, deadline-poll each container's `burn-<svc>.jsonl` under
  `docker/burn/results/`, assert 4/4 `"clean":true` rows, compose down -v on
  every path. Exit 0 / 1 not-4/4 / 2 docker-or-image preflight. `--dry-run`.
- `docker/burn/compose.burn.yml` — 4 self-contained `smalt:local` services
  (YAML anchor), no host port mappings (no collisions with concurrent lanes);
  each runs `docker/burn/container-burn.sh`: boot release, atom-flood its own
  AMQP port, assert zero `[amqp-atom] ... :closed` log lines, emit one JSONL
  row, exit 0/1. Bash-only (no python in the runtime image).
- `docker/burn/container-burn.sh` — in-container probe described above.
- `justfile.d/30-burn.just` — `burn`, `burn-soak`, `burn-chaos` (8 hogs,
  1 round), `burn-matrix`, `burn-clean` (lane-clean + burn-project
  `compose down -v` + `docker volume prune -f` + results reclaim).
  Imported as `import 'justfile.d/30-burn.just'` (justfile line 254).

## Witnessed validation (real output)

```
$ bash -n docker/burn/soak.sh docker/burn/parallel-matrix.sh docker/burn/container-burn.sh
bash-n OK x3

$ docker compose -f docker/burn/compose.burn.yml config   # exit 0
compose config OK

$ just burn-soak --dry-run
[BURN-SOAK][DRY-RUN] root=/Users/sac/smalt rounds=3 hogs=4 flood_seconds=20 amqp_port=5672
[BURN-SOAK][DRY-RUN] jsonl=/Users/sac/smalt/tmp/burn-soak-20261018T213716Z.jsonl ledger=/Users/sac/smalt/docs/jira/v26.10.17/FLAKE_LEDGER.md
[BURN-SOAK][DRY-RUN] plan: start 4 yes-hogs -> atom-flood 127.0.0.1:5672 (partial HTTP + mid-request close) -> 3 x (mix test + mix test --include amqp_wire) -> classify vs FLAKE_LEDGER -> jsonl rows

$ just burn-matrix --dry-run
[BURN-MATRIX][DRY-RUN] compose_file=/Users/sac/smalt/docker/burn/compose.burn.yml project=smalt-burn
[BURN-MATRIX][DRY-RUN] services=smalt-burn-1 smalt-burn-2 smalt-burn-3 smalt-burn-4
[BURN-MATRIX][DRY-RUN] results_dir=/Users/sac/smalt/docker/burn/results deadline=900s
[BURN-MATRIX][DRY-RUN] plan: compose up -d -> deadline-poll burn-<svc>.jsonl x4 -> assert 4/4 clean -> compose down
```

Classifier unit witness (synthetic ExUnit failure block through the exact
classifier logic shipped in soak.sh):

```
[{'face': 'test/arm_error_corpus_test.exs:274', 'standing': 'CLOSED'},
 {'face': 'test/egress_dispatch_test.exs:1221', 'standing': 'OPEN-ROTATING'},
 {'face': 'test/novel_test.exs:9', 'standing': 'UNLEDGERED']}
```

## Boundary (not executed in this lane)

Live `just burn-soak` (~45-90 min under load) and live `just burn-matrix`
(needs image `smalt:local` present) are not executed here — next-lane
closure with the same scripts. Shellcheck printed one SC2155 warning, and it
came from the sibling lane's docker/burn/boot-burn.sh; this lane's three
scripts are clean.

## Sibling-lane disclosure (compile-freeze disclosure law)

`docker/burn/boot-burn.sh` appeared in docker/burn/ mid-lane, written by a
sibling lane (50-cycle boot/probe/teardown container burn). Not this lane's
file; left untouched, no overlap with soak.sh / parallel-matrix.sh /
compose.burn.yml / container-burn.sh. burn-clean does not delete it.
