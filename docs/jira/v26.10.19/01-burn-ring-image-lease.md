# V261019-01 — Burn-ring re-run under flock image-build lease + SUBJECT_SHA build-arg fix

- **Release:** v26.10.19
- **Lane:** burn-ring
- **Base:** HEAD `4fd2ff2ba80e618341dc85de3ef84fcb8702bff3`
- **Status:** ready-for-work

## Objective

Unblock the third-strike-blocked `just burn-ring` re-judge. The ring never
re-ran in v26.10.18 (6 docker builds, 0 ring runs) — the zombie repair face is
ALIVE, but B2/B3 (AZB-22 ring subject binding) carry as TYPED-OPEN
(`docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md`, Amendment 1). Two
mechanical root causes, both on this lane:

1. **Stale baked subject.** `docker/Dockerfile:26` pins a default
   `ARG SUBJECT_SHA=29bb0371426a270c9c9ac2dc483b7e2a9d226938` (the old
   checkpoint-6 head), so `LABEL org.smalt.subject` and
   `ENV SMALT_BURN_SUBJECT_SHA` (`docker/Dockerfile:26-32`) are stale on
   arrival unless overridden at build time. Fix: always pass
   `--build-arg SUBJECT_SHA=$(git rev-parse HEAD)` (BUILD_RECEIPT.md command)
   AND update/remove the default — a required build-arg with no stale fallback
   is the preferred shape.
2. **Concurrent build race.** 4 concurrent `docker build` PIDs were witnessed
   (`docs/jira/v26.10.18/receipts/azb-22b-zombie-fix.md` ~line 170); two lanes
   baked different SHAs while HEAD moved under them. Fix: an image-build lease
   per `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` line 69 — flock on
   a build lockfile, build at a pinned SHA, verify HEAD unchanged post-build,
   release only after boot-stage verification — the same discipline as
   `scripts/substrate.sh`.

## Files owned (this lane)

| File | Scope |
|---|---|
| `docker/Dockerfile` | `SUBJECT_SHA` ARG default fix (line 26 area) |
| build-driver script (new, e.g. `scripts/build_burn_image.sh` — or the `just` recipe owning `docker build`) | flock lease, pinned-SHA build, post-build HEAD verification |
| `docs/jira/v26.10.19/receipts/` (new receipt) | ring re-run witness + lease discipline record |

**NOT owned by this lane:** `scripts/validate_burn.py` (standing-derivation
fix already landed per `docs/jira/v26.10.18/receipts/i29-validator-standing-fix.md`);
`docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md` register (lane 02);
colima/host disk management (coordinator concern). Other lanes must go through
the lease, never bypass it.

## Tasks

### Task 1 — Dockerfile SUBJECT_SHA default
At `docker/Dockerfile:26`: either remove the stale `29bb0371…` default in
favor of a required build-arg, or repin the default to the ring SHA at cut
time with a comment pointing at the lease script. Keep the
`ENV SMALT_BURN_SUBJECT_SHA=${SUBJECT_SHA}` passthrough intact (runtime
receipt emitters need 40-hex).

### Task 2 — image-build lease
Flock on a shared lockfile (pattern: `scripts/substrate.sh`) around:
(a) `RING_SHA=$(git rev-parse HEAD)` pin, (b) `docker build
--build-arg SUBJECT_SHA=$RING_SHA ...`, (c) post-build re-check
`git rev-parse HEAD == $RING_SHA` else abort (do not boot a moved-HEAD
image), (d) boot-stage subject verification, then release.

### Task 3 — ring re-run
`just burn-ring` at the pinned SHA; confirm
`org.smalt.subject == $RING_SHA` on the booted image; burn receipt derived
standing via `scripts/validate_burn.py` (all plane rows clean).

### Task 4 — receipts + register flips
Write the ring receipt; flip `AZB23-PREFLIGHT.md` B2/B3 BLOCKED→PASS citing
it. Third-strike rule applies: a further ring failure retires the ring shape.

## Acceptance criteria

```bash
git rev-parse HEAD   # = RING_SHA used in the build
docker inspect <ring-image> --format '{{ index .Config.Labels "org.smalt.subject" }}'
# must equal the pinned SHA above
grep -n "SUBJECT_SHA" docker/Dockerfile   # no stale 29bb0371 default
just burn-ring   # completes; validate_burn.py derives standing ALIVE, exit 0
```

## Falsifier

On the pre-fix tree: launch two concurrent builds of `docker/Dockerfile`
without the lease while HEAD moves between them — at least one image carries
`org.smalt.subject != $(git rev-parse HEAD)`. Post-fix, the same scenario is
impossible (second builder blocks on the flock; a HEAD move aborts the boot).
Re-run the ring once more; a third infra strike retires the ring shape per the
work order.
