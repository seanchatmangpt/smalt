# WO-1 lane receipt — SUBJECT_SHA required-arg + flock image-build lease

Standing: **ALIVE** (both fixes landed and witnessed with real builds)

## Fixes landed

1. `docker/Dockerfile` — stale `ARG SUBJECT_SHA=29bb0371…` default removed;
   SUBJECT_SHA is now a REQUIRED build-arg with a build-time validation
   stanza (must be 40-hex, build REFUSES otherwise). The
   `ENV SMALT_BURN_SUBJECT_SHA=${SUBJECT_SHA}` passthrough is kept.
2. `scripts/build_burn_image.sh` (NEW, executable) — flock image-build lease
   (`/tmp/smalt-burn-image.lock` on fd 9) around: SHA pin →
   `docker build --build-arg SUBJECT_SHA=$RING_SHA` → post-build HEAD
   equality check (typed abort `HEAD_MOVED`) → `docker inspect` label
   equality (typed abort `IMAGE_SUBJECT_MISMATCH`) → release. Children
   spawned with lock fd discipline; `DOCKERCmd` env override for testability;
   `--tag <name> --dry-run` flags.

## Witnesses (real output)

### bash -n

```
$ bash -n /Users/sac/smalt/scripts/build_burn_image.sh && echo "bash-n:PASS exit=$?"
bash-n:PASS exit=0
```

### Dry-run (no lock taken, no build)

```
$ ./scripts/build_burn_image.sh --tag smalt:wo1-witness --dry-run
RING_SHA(pinned)=64f6099663a4ec32fd9478c4c39fca49ab1961f8
TAG=smalt:wo1-witness
LOCKFILE=/tmp/smalt-burn-image.lock
DRY-RUN plan (no lock taken, no build):
  exec 9>/tmp/smalt-burn-image.lock; flock -x 9
  docker build -f docker/Dockerfile -t smalt:wo1-witness --build-arg SUBJECT_SHA=64f6099663a4ec32fd9478c4c39fca49ab1961f8 \
      --build-context ash_r2rml=~/ash_r2rml --build-context ash_graphlaw=~/ash_graphlaw \
      --build-context ggen_igniter=~/ggen_igniter .
  git rev-parse HEAD  # must equal 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (typed abort: HEAD_MOVED otherwise)
  docker inspect --format {{.Config.Labels}} smalt:wo1-witness  # org.smalt.subject must equal 64f9... (full line above)
  flock -u 9; exec 9>&-  # release
dry-run-exit:0
```

### Negative: docker REFUSES to build without SUBJECT_SHA (exit 1)

```
#5 [base 2/4] RUN test -n "$SUBJECT_SHA" || { echo "FATAL: SUBJECT_SHA build-arg is required ...
#5 0.118 FATAL: SUBJECT_SHA build-arg is required (pass --build-arg SUBJECT_SHA=$(git rev-parse HEAD))
#5 ERROR: process "/bin/sh -c ..." did not complete successfully: exit code: 1
neg-exit:1
```

### Positive: real `--target base` build with pinned SHA, label inspect (exit 0)

```
$ docker build --target base -f docker/Dockerfile -t smalt:wo1-base-witness \
    --build-arg SUBJECT_SHA=$(git rev-parse HEAD) .   # exit 0, 30.9s export
$ docker inspect --format '{{index .Config.Labels "org.smalt.subject"}}' smalt:wo1-base-witness
64f6099663a4ec32fd9478c4c39fca49ab1961f8
```

### Stubbed-DOCKERCmd logic witness (happy + typed mismatch abort)

```
$ DOCKERCmd=/tmp/wo1-stub/bin/docker ./scripts/build_burn_image.sh --tag smalt:stub
...
lease: acquired (flock -x 9)
head-check: HEAD unchanged (64f6099663a4ec32fd9478c4c39fca49ab1961f8)
label-check: org.smalt.subject=64f6099663a4ec32fd9478c4c39fca49ab1961f8 == pinned
lease: released
BUILD_RECEIPT subject=64f6... lease=PASS label=PASS head=PASS
stub-happy-exit:0
--- mismatch stub ---
TYPED-FAIL[IMAGE_SUBJECT_MISMATCH]: org.smalt.subject=deadbeef != pinned SUBJECT_SHA=64f6...
stub-mismatch-exit:1
```

### Full real build through the script (leased path end to end)

```
$ ./scripts/build_burn_image.sh --tag smalt:wo1-full-witness
... (release stage: "Release created at /app/_release"; export 90.2s)
head-check: HEAD unchanged (64f6099663a4ec32fd9478c4c39fca49ab1961f8)
label-check: org.smalt.subject=64f6099663a4ec32fd9478c4c39fca49ab1961f8 == pinned
lease: released
BUILD_RECEIPT subject=64f6099663a4ec32fd9478c4c39fca49ab1961f8 tag=smalt:wo1-full-witness lease=PASS label=PASS head=PASS
full-build-exit:0
```

Post-build inspect (independent re-check):

```
$ docker inspect --format '{{index .Config.Labels "org.smalt.subject"}}' smalt:wo1-full-witness
64f6099663a4ec32fd9478c4c39fca49ab1961f8
```

## Scope notes

- Docker daemon was AVAILABLE (`docker info` exit 0, server 29.5.2 / Ubuntu
  24.04.4), so real-build witnesses were taken per brief (no typed-skip).
- WO-1 close condition (`just burn-ring` re-run clearing AZB23-PREFLIGHT
  B2/B3) remains with the ring lane — this receipt covers the two mechanical
  root-cause fixes only.
- `/tmp/wo1-stub` scratch dir could not be removed (rm denied by permission
  system); harmless /tmp scratch, no repo state.
- No git operations performed (lane rule). Receipt context: Context: solo.

Context: solo
