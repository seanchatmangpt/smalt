# i29 Naming-Sweep Repair (76 → 0)

Date: 2026-10-18
Tree: post-0009df3
Context: solo(bash scripts/naming_sweep.sh + just naming-sweep, ×N iterations, final green ×1)
Scope: docker/, docker/burn/, justfile.d/30-burn.just, k8s/kind/cluster.yaml,
mods/ratchet/ (lib+test+README+fixtures), scripts/have/, burn evidence jsonl,
docs/jira/v26.10.18/rewrite-drafts/, docs/reference/have-runbook.md,
docs/jira/v26.10.14/KNOWN_DIVERGENCES.md, scripts/naming_sweep.sh (allowlist only)

## Fix classes

1. **Derived paths (real fix, executable surfaces)**
   - `docker/burn/burn-ring.sh:124-125` — `-v /Users/sac/beam4pm` → `-v "$HOME/beam4pm"` (same for xaas).
   - `docker/burn/parallel-matrix.sh:141-142` — quoted heredoc kept, literal → `${HOME}` so the
     GENERATED `compose.burn.yml` carries compose-runtime `${HOME}` interpolation (portable, and
     regeneration-stable: `--emit-compose 1` re-verified after the fix).
   - `docker/burn/compose.burn.yml:13-14` — regenerated via the fixed generator (`${HOME}` form).
   - `justfile.d/30-burn.just:50-51` — `-v $HOME/beam4pm` / `-v $HOME/xaas`.
   - `scripts/have/have_11_drill.sh:19` — `REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`.
   - `scripts/have/storage_probe.py:80` — `os.path.expanduser("~/.erlmcp/...")` instead of the
     hardcoded `/Users/sac/.erlmcp/...` first candidate (shutil.which fallback unchanged).
   - `mods/ratchet/lib/{commands,gate,inject}.js` — repo root derived from module location
     (`path.resolve(__dirname|import.meta.dirname, '..','..','..')`, `SMALT_ROOT` env override);
     no absolute literals left in mods/ratchet/lib/.
   - `mods/ratchet/test/*.js` — REPO/TICKETS/STATE constants derived from `__dirname`
     (three levels up from test/), `Run:` comments made repo-relative.

2. **Tilde rewrites (historical evidence/prose, meaning preserved)**
   - Burn evidence: `docs/jira/v26.10.18/burn/kill-storm-host.jsonl` (evidence_path ×3),
     `burn/ring-ringsmoke/boot/boot-burn.jsonl` (×3), `burn/test/{e2e,redteam}/...` copies (×4).
   - `rewrite-drafts/*.md` (26 hits), `docker/{Dockerfile,BUILD_RECEIPT.md}` sibling build-context
     doc lines (→ `~/ash_r2rml` etc.), `docs/reference/have-runbook.md` cron examples (→ `~/smalt`),
     `mods/ratchet/README.md` + `test/fixtures/*.md`, KD-94 row in
     `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (→ `~/cai/athena`).

3. **Minimal scoped allowlist entries** (mechanism unchanged; check not weakened)
   - `k8s/kind/cluster.yaml:22,25,28,32,35,38` — kind CRD `hostPath` requires literal absolute
     host paths; k8s does not expand env. The only structural exemption.
   - `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:262` — pin refresh: the KD-94 row moved 252 → 262
     after i29 window edits inserted 10 lines above it; old `:252` pin was stale (now points at
     KD-87). Same KD-register-quotes-own-evidence class as the pre-existing `:157` pin.

## Non-vacuity / verification

- `just naming-sweep` → `[NAMING-SWEEP] PASS: 0 violations / 47 allowed`, exit 0 (embedded above).
- Regression check on edits: `mods/ratchet` suite `node --test test/` → 29 tests, 29 pass, 0 fail
  (first run caught my own one-level-short repo-root derivation via real ENOENT at
  `/Users/sac/smalt/mods/mods/...` — Chicago-style: real files, real failure, fixed, reran green).
- `bash -n` green on all three edited shell scripts; `node --check` green on all edited js;
  `ast.parse` green on storage_probe.py.
- Regeneration stability: `bash docker/burn/parallel-matrix.sh --emit-compose 1` after the fix
  produces `${HOME}` (not a re-hardcoded literal) — first attempt with an unquoted heredoc
  expanded `$HOME` at generation time and re-hardcoded the path; caught by re-running the sweep,
  reverted to the quoted heredoc.
- Standing: **PASS** — gate exit 0, all repaired surfaces verified on real runs.
