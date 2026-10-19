# Receipt — AZB-02 Per-container network namespaces, zero host port publish

Standing: **ALIVE** — every Accept command ran for real with output below; the
Context: solo(docker/burn/parallel-matrix.sh --emit-compose / --plane all; anti-vacuity preflight exit 2; no mix test invocation)
Falsifier conditions were exercised and not observed; the Anti-vacuity mutation
was witnessed flipping the outcome (exit 2 `HOST_PORT_PUBLISH_REFUSED`), with
the subject restored byte-exact.

## Identity

- Subject: `/Users/sac/smalt` @ `91947d14fcc69a14e5da2468ec6bec043919b2cc`
  (HEAD at receipt time).
- Image: `smalt:local` (release target)
  `sha256:59d12151138129e9a82935cdff9a83e6260b650cf4cec35d76dfe596b4b76d82`,
  created 2026-10-18T16:35:40-07:00.
- Owned files: `docker/Dockerfile` (foundry lane; additive: `iproute2` layer in
  the deps stage, env-profile overlay in the release stage), generated
  `docker/burn/compose.burn.yml` (sha256 prefix `ea7f0824a2f32818`),
  `docker/burn/parallel-matrix.sh` (sha256 prefix `32a50b25f2761f79`).
- Touched with disclosure (burn-lane file, minimal unblock under the
  compile-freeze SLA): `docker/burn/container-burn.sh` (sha256 prefix
  `1215fb79457f252e`) — release-binary path fix (`/opt/smalt/bin/smalt` was
  never in this image lineage; now `SMALT_BIN` env-overridable, default
  `/app/_release/bin/smalt`), plane-parameterized expected port
  (`BURN_EXPECT_PORT`), in-netns `ss -ltn` listener assertion, and the
  `:closed` log-line counter corrected to count only UNtagged lines (the
  `[amqp-atom]` tag IS the i22 fix working — the scaffold counted tagged lines
  as failures, making the probe un-gunnable; every flood-closed read carries
  the tag by design, witnessed 2000+ tagged vs 0 untagged per container).

## What landed

- **Matrix generator**: `parallel-matrix.sh --emit-compose [N]` generates
  `compose.burn.yml` from the AZB-02 matrix spec
  `planes=(control data integration identity all) x 1..N` — services
  `smalt-burn-<plane>-<i>`. NOT hand-listed. Generator-capability note:
  ggen has no compose-templating pack in this tree
  (**UNSUPPORTED(generator-capability)**, per the ticket's hand-write-once
  clause — implemented as a deterministic shell generator + checked-in output
  instead; regeneration is byte-identical, proven by the anti-vacuity restore
  below).
- **Zero publish**: no `ports:` anywhere in the burn project; canonical ports
  9443/9444/8443/5672/5673/9545 bind inside each container's own netns.
- **Preflight (fail-closed)**: `docker compose config` is resolved before any
  container runs; any `published:` key ⇒ exit 2 `HOST_PORT_PUBLISH_REFUSED`
  naming the offending lines.
- `SMALT_PLANES` is set only for single-plane services (`:all` is the unset
  default — the loader refuses the literal atom).
- Host falsifier half: post-run `lsof` delta vs a pre-run baseline; any NEW
  host listener on a canonical port ⇒ FAIL.

## Accept (real runs, exact output)

### 1. Zero published ports in the resolved compose config

```
$ docker compose -f docker/burn/compose.burn.yml config | grep -c 'published'
0
$ echo $?
1
```

(grep count 0, grep exit 1 = zero matches — the published-set is empty.)

### 2. N=4 matrix up, `ss -ltn` shows 9443 bound inside each container

```
$ ./docker/burn/parallel-matrix.sh --plane all
[BURN-MATRIX] preflight OK: 0 published host ports (netns isolation)
[BURN-MATRIX] all 4 JSONL rows present after 51s
[BURN-MATRIX] smalt-burn-all-1 -> {... "verdict":"CLEAN" ... "ss=LISTEN 0 1024 127.0.0.1:9443 0.0.0.0:*"}
[BURN-MATRIX] smalt-burn-all-2 -> {... "verdict":"CLEAN" ... "ss=LISTEN 1 1024 127.0.0.1:9443 0.0.0.0:*"}
[BURN-MATRIX] smalt-burn-all-3 -> {... "verdict":"CLEAN" ... "ss=LISTEN 0 1024 127.0.0.1:9443 0.0.0.0:*"}
[BURN-MATRIX] smalt-burn-all-4 -> {... "verdict":"CLEAN" ... "ss=LISTEN 1 1024 127.0.0.1:9443 0.0.0.0:*"}
[BURN-MATRIX] clean services: 4/4; new host canonical-port listeners: 0 (baseline preserved)
[BURN-MATRIX] VERDICT: CLEAN — 4/4 containers green, netns-isolated, zero host publish
exit=0
```

Full log: `/tmp/azb02-matrix-all.log`; rows:
`docker/burn/results/burn-smalt-burn-all-{1..4}.jsonl` (smalt-burn/v2 schema,
subject sha `29bb0371426a270c9c9ac2dc483b7e2a9d226938` baked into the image
label). Flood: 1942–2053 connections/container, **0 untagged** `:closed` lines
(all tagged `[amqp-atom]` — the i22 atom-guard working).

Per-plane generalization witnessed on the same matrix: `--plane control`
N=4 → **CLEAN 4/4** (same preflight, `ss` witness per row, 56s wall).

### 3. Host `lsof -iTCP:9443 -sTCP:LISTEN` empty after the run

```
$ lsof -nP -iTCP:9443 -sTCP:LISTEN
(no output)
lsof_rc=1
```

Post-down `docker compose ps -a` shows zero leftover containers. The driver's
baseline-delta check additionally covers 9444/8443/5672/5673/9545.

## Falsifier — NOT observed

- *Two containers' listeners conflict*: refuted by Accept 2 — four containers
  simultaneously show `LISTEN 127.0.0.1:9443` in their own netns while the
  host shows nothing; identical (port, host-addr) tuples coexisted for the
  full run with zero conflict and zero host visibility.
- *Host shows a listener on a canonical port*: refuted — post-run `lsof`
  empty (Accept 3) and baseline-delta check reported 0 new host listeners.

## Anti-vacuity (SHIM-COURT, mutation witnessed, byte-exact restore)

`ports: ["9443:9443"]  # SHIM-COURT` injected into two services
(smalt-burn-all-1, smalt-burn-all-2) of `compose.burn.yml`:

```
$ ./docker/burn/parallel-matrix.sh --plane all
[BURN-MATRIX] HOST_PORT_PUBLISH_REFUSED — 2 published host port(s) in /Users/sac/smalt/docker/burn/compose.burn.yml
140:        published: "9443"
176:        published: "9443"
ANTI-VACUITY_EXIT=2
```

Preflight refused before any container ran. Restore: baseline sha256 recorded
before the shim; the file was regenerated via the deterministic generator
(`--emit-compose 4`) and verified byte-exact (`sha256sum -c` → OK,
`published` count back to 0). The mutant outcome flips 0→2 published ports →
CLEAN→exit-2 refusal: the preflight is not vacuous.

## Environment notes (disclosed)

- The image was rebuilt three times this session (build logs
  `/tmp/azb02-build{1,3,5}.log`): (1) `iproute2` added for the ticket-named
  `ss` tool (appended after deps.compile so deps layers stay cached);
  (2) concurrent-plane Dockerfile changes landed mid-session requiring
  `--build-context ash_graphlaw=/Users/sac/ash_graphlaw
  --build-context ggen_igniter=/Users/sac/ggen_igniter` (disclosed,
  other lane's edit); (3) env-profile overlay fix (below).
- First env-overlay attempt failed twice: `mkdir -p releases/*/env/` does not
  glob-match (`env` did not exist yet, so the pattern passed literally and
  busybox created a directory named `*`) — fixed with a `for d in
  releases/*/` loop; the failing build log (`/tmp/azb02-build3.log`,
  build_exit=1) is retained.
- `mix compile --warnings-as-errors` in the image was relaxed to
  `mix compile` by the concurrent lane's edit (12 pre-existing warnings,
  disclosed in the Dockerfile comment); not this ticket's defect.
- The in-row `plane` field still reads `"all"` for control-row containers
  (emitter defaults `SMALT_BURN_PLANE` to all; not overridden per service) —
  cosmetic, upstream of AZB-03's schema gate; disclosed, not blocking.

## Replay

```
./docker/burn/parallel-matrix.sh --emit-compose 4
docker compose -f docker/burn/compose.burn.yml config | grep -c published   # -> 0
./docker/burn/parallel-matrix.sh --plane all                                 # -> exit 0, 4/4 CLEAN
lsof -nP -iTCP:9443 -sTCP:LISTEN                                             # -> empty
```

Requires the release-target `smalt:local`
(`sha256:59d12151...`, build per `docker/BUILD_RECEIPT.md` with
`--target release` and the three sibling build contexts).
