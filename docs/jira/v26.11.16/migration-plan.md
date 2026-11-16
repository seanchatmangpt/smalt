# smalt migration plan v26.11.16

Standing: UNVERIFIED

## Identity
- Path: /Users/sac/smalt
- Remote: https://github.com/seanchatmangpt/smalt.git
- Branch: main@aa094e86, upstream origin/main
- Last commit: 2026-11-15; commits: 514; size: 13,588 MB (13.3 GB)
- Languages/build: Elixir (mix.exs, _build, deps), package.json, Justfile, Terraform provider,
  Python scripts (scripts/mutation_court.py), Erlang bench/
- Nested repos: none

## Observed state
- dirty=10: bench/bench_concurrency_ceiling.erl, docs/BENCHMARKS.md, 3 files under
  docs/jira/v26.11.6/ (incl. bench/bc.jsonl), scripts/mutation_court.py, 4 integration tests
  (kd_conformance, signins_log, sqs_roundtrip, tenant_registry)
- untracked=4: docs/jira/v26.11.15/ (plus three more not listed in head)
- ahead=0 behind=0; stash=0
- Unpushed local branches: chore/rm-impl14-artifacts @0acc51b0, main-pre-squash-20261029
  @8d88d7ac (pre-squash safety branch)
- Build dirs: _build 375 MB, deps 61 MB
- Heavy non-build dirs: tmp/ 2.8 GB, scripts/ 1.5 GB, docs/ 1.4 GB, .git 895 MB,
  workspace/ 881 MB, _bench-aq/ 744 MB, adapters/ 529 MB, popcorn_demo/ 483 MB
- History note: main-pre-squash branch untracked >100 MB blobs (explorer NIF .so 207 MB,
  ocel-1m.ndjson 298 MB), so .git still carries them unless gc'd.
- Local-only files: .env.example only; submodules: none

## What it is
smalt: pure-Elixir, BEAM-native local cloud-edge emulator (ARM-style control plane on 9443,
data plane 8443, Service Bus/Event Hubs, MCP surface on 9545) under P28-SIL licence; now
pivoting to a closed-world standards engine with SHACL admission and BLAKE3 turnstile.

## Classification
ACTIVE (census agrees: committed yesterday, 22 jira dirs).

## Migration risk
- 10 modified test/bench/doc files and v26.11.15 jira dir not committed.
- main-pre-squash-20261029 is the only copy of pre-squash history (local-only branch).
- 13 GB on disk, of which >9 GB is tmp/, benches, demos and scripts data that is likely
  untracked or gitignored; if any is real data it would be lost on CLONE-FRESH.
Rate: MEDIUM

## Recommended action
COMMIT-PUSH
1. `cd /Users/sac/smalt && git add docs/jira/v26.11.15 && git add -u && \
   git commit -m "test/bench: v26.11.15 integration test and bench updates"`
2. `git push origin main`
3. `git push -u origin main-pre-squash-20261029 chore/rm-impl14-artifacts` (DECISION: or
   `git bundle create /Volumes/ARCHIVE/smalt-pre-squash.bundle main-pre-squash-20261029`
   if that history should not go to GitHub).
4. `rm -rf _build deps node_modules` (436 MB).
5. `git status --porcelain --ignored | grep '^!!' | head -40` to list ignored data dirs;
   DECISION per dir (tmp/, _bench-aq/, workspace/, popcorn_demo/, adapters/): rsync to the
   archive volume or drop. Default: drop tmp/ and _bench-aq/, rsync workspace/ only.
6. CLONE-FRESH on the new machine.

## First commands on the new machine
`git clone https://github.com/seanchatmangpt/smalt.git && cd smalt && mix deps.get && \
mix test` then `just --list` (stated, not run).

## See Also
- ../v26.11.15/
- /Users/sac/docs/jira/v26.11.16/README.md
