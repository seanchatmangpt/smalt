# Gap 05 — CI/CD estate comparison (smalt vs courtroom-platform-az)

Lane 5 of 12, wave v26.10.30. Read-only comparison of
`/Users/sac/cai/courtroom-platform-az/.github/workflows/{ci,infra-dev,deploy-dev}.yml`
vs `/Users/sac/smalt/.github/workflows/{ci,kind-swarm,posh-go.yml}`.

## Status line

**PARTIAL** — all workflows read on disk this session (receipts below); no workflow
executed in this lane (read-mostly lane, one-file deliverable). Every claim below is
file:line-cited from the on-disk workflow YAML.

## Evidence base

- courtroom-platform-az HEAD `31c58e9` — 3 workflows: `ci.yml`, `infra-dev.yml`,
  `deploy-dev.yml`
- smalt HEAD `f0e0a125` — 3 workflows: `ci.yml`, `kind-swarm.yml`, `posh-go.yml`

## Comparison summary

| Dimension | courtroom-platform-az | smalt |
|---|---|---|
| Trigger coverage | PR + push(main) + dispatch | push(main, path-filtered) + PR; kind-swarm push-only |
| Environments / approvals | `dev-infra-plan`, `dev-infra`, `dev` GH environments | none |
| OIDC / cloud auth | Azure OIDC (`id-token: write`, `ARM_USE_OIDC`) | none (no cloud substrate in CI) |
| Secrets scanning | trivy secret scan job, exit-code 1 | none |
| Image scanning | trivy on both images, exit-code 1 | none |
| Deps audit | `npm audit --omit=dev --audit-level=high` | none in CI (Dependabot PRs only) |
| Terraform in CI | fmt+validate all env roots; OIDC plan + gated apply | fixture-tier plan only (`scripts/tf_fixtures`) |
| Real-substrate proof | container health checks post-run, both images | ci.yml boots substrate for TF fixture only |
| Courts (shim/kind/posh) | n/a | **none in any workflow** |
| Dependabot | npm + github-actions + terraform | gomod only (posh, provider) |
| Artifact retention | none | provider binary 7 days (posh-go) |

## Gaps

| # | Gap | Evidence | Severity | Close condition |
|---|---|---|---|
| a | **No workflow runs posh-court or the kind courts on PRs.** `kind-swarm.yml` builds the burn + hermetic images with the same `SUBJECT_SHA` 40-hex label contract as `scripts/build_burn_image.sh`, runs the canonical `docker/compose.smalt.yml` on the `host` backend, and on the `kind` backend creates a kind cluster from the canonical `k8s/kind/cluster.yaml` (host-local `extraMounts` stripped via yq), applies `smalt-deployment.yaml` with `__SUBJECT_SHA__` sed'd, and witnesses cross-pod ping + the port-mapped 9443 face. It is a real end-to-end k8s/swarm proof — but triggers are `push` to main (path-filtered) + `workflow_dispatch` only; there is no `pull_request` trigger. smalt `ci.yml` runs compile/tests/TF fixture only; `grep -rn court .github/workflows/` → zero matches. The `just shim-court` harness (`justfile.d/18-shim-court.just`) and sleep-gate courts have no CI wrapper at all. | `kind-swarm.yml:21-29` (no `pull_request`), `ci.yml` (no court job), `grep -rn court .github/workflows/` empty | **High** — the strongest verification machinery in the estate (courts) never gates a merge; a PR can be merged with courts red or unrun. | Add `pull_request` trigger to `kind-swarm.yml`; add a `courts` job to ci.yml (or a `courts.yml`) invoking `just shim-courts` + `just sleep-gate` on PRs. Gate: a deliberately red court PR fails CI. |
| b | **No path from smalt-green to courtroom-platform-az deploy.** `deploy-dev.yml` gates only on its own CI via `workflow_run` on `[CI]`; no `repository_dispatch`/`workflow_call`/`workflow_run` listener for smalt, and smalt emits none. Two repos, zero cross-repo gate: courtroom deploys an API that may consume a smalt substrate at a version no court has qualified. | `deploy-dev.yml:11-14` (workflow_run on CI only), smalt workflows have no outbound trigger | **Medium** — real coupling exists (courtroom consumes smalt), but there is no current evidence of an unpinned broken-consumption incident. | Decide the contract: either courtroom pins smalt by digest/SHA and Dependabot-proposes bumps gated on smalt's CI status, or courtroom adds a `workflow_run`-class listener on smalt's CI and re-runs its own integration court. Gate: a red smalt main blocks the next courtroom deploy. |
| (c) | **consumer terraform apply is workflow_dispatch-only; access root has no pipeline.** `infra-dev.yml` plan job runs on PR+push for `infra/**`, but `apply` is `if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'` (line 55) against `dev-infra` environment. The `infra/environments/dev/access` root exists on disk (`ls infra/environments/dev/` → access, platform) and is in Dependabot's terraform list, but infra-dev's `working-directory` is `infra/environments/dev/platform` only — access root has plan or apply anywhere. | `infra-dev.yml:55` (dispatch-only apply), `infra-dev.yml:68` (platform working-directory); `infra/environments/dev/access/` exists with no workflow reference | **Medium** — plan-on-PR covers platform drift review; apply-by-dispatch is a defensible gated-manual posture; the access root is the actual hole (unreviewed, unplaned, unapplied drift possible). | (1) Add access-root plan to infra-dev (matrix over `{platform,access}`); (Drift detection: scheduled `terraform plan -detailed-exitcode` for both roots; apply can stay dispatch-only + environment-gated. Gate: an out-of-band access-root change surfaces as a red scheduled plan within one schedule interval. |
| d | **posh-go CI never runs live tests (TFPOSHT_LIVE unset) — no substrate in CI.** The workflow's own header states it: "Live tests stay skipped: TFPOSHT_LIVE is never set here, so `live_test.go` gates off." Both `go test` steps run without `TFPOSHT_LIVE`; no step boots a smalt substrate (contrast smalt ci.yml, which boots `mix run --no-halt` and polls port 9443 for the TF fixture tier). The provider is built and archived but never exercised against a live substrate. | `posh-go.yml:16-17` (header comment), `posh-go.yml` provider `go test` step (no TFPOSHT_LIVE) | **Medium-High** — the provider's entire live surface is unverified in CI; the binary in the 7-day artifact is compile-checked, not behavior-checked. smalt's own CI proves the substrate-in-CI pattern works (port-9443 poll + TF plan). | Add a job (or step in `provider`) that boots smalt via `mix run --no-halt` + port-9443 poll (copy ci.yml's pattern), exports `TFPOSHT_LIVE=1`, runs `go test -run TestLive ./...`. Gate: `TFPOSHT_LIVE=1 go test ./...` green on a runner with the substrate up; red substrate = red job. |
| e | **Dependabot coverage vs ecosystem drift.** smalt dependabot.yml lists exactly two `gomod` entries (posh, terraform-provider-smalt). Missing ecosystems: Elixir (mix.exs — the substrate's primary language), docker (Dockerfile, Dockerfile.hermetic, compose.smalt.yml), github-actions (smalt's actions are largely tag-pinned `@v4`/`@v1`, unlike courtroom's SHA-pinned), terraform (`scripts/tf_fixtures` uses hashicorp/setup-terraform@v3 unpinned). Meanwhile courtroom-platform-az covers npm + github-actions + terraform. Ecosystem drift: smalt's heaviest dependency surfaces (Elixir deps, actions) have no automated update channel. | smalt `.github/dependabot.yml` (gomod only); smalt ci.yml uses `actions/checkout@v4` tag-pins vs courtroom ci.yml SHA-pin comments (`@3d3c42e... # v7.0.1`) | **Low-Medium** — hygiene drift, not correctness today; tag-pinned actions are a supply-chain exposure courtroom already closed. | Add `mix` (hex via mix.exs is not a native Dependabot ecosystem — use `elixir` custom/`mix` ecosystem or Renovate), `docker`, and `github-actions` entries; SHA-pin smalt's actions like courtroom does. Gate: dependabot config lint green + at least one automated PR per new ecosystem. |
| f | **Large-files warning from the last push — no git-lfs.** `git count-objects -vH` → size-pack **846.74 MiB**; `.gitattributes` does not exist (no LFS anywhere). Tracked large files: `test/priv/graphlaw/graphlaw.wasm` 74 MB, `_impl14/test/.../libwasmex...so` 50 MB, `popcorn_demo/bench/corpus/ocel-100k.ndjson` 30 MB, `posh/server.test` 9.6 MB, `workspace/public/wasm/graphlaw.wasm` 6.6 MB, `docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl` 4.4 MB. Untracked large residue is ignored correctly (`erl_crash.dump`, `posh/bin/` binaries, `tmp/*.log` pass `git check-ignore`, exit 0). So the warning is entirely from tracked blobs; every future clone pays the 847 MiB. | `git count-objects -vH`, `git ls-files | xargs stat` top-8 table above, no `.gitattributes` | **Low** (hygiene, monotonic cost) — no correctness impact, but repo size is monotonic and the wasm is re-bundled per land. | Either (1) `git lfs migrate import` the wasm/so/ndjson corpus (irreversible history rewrite — needs the merge-only policy note), or (2) forward-fix: add `.gitattributes` LFS patterns for `*.wasm`, `*.so`, `*.ndjson` + move one-off bench corpora to an artifact store. Gate: next clone size measured < 100 MiB pack on a scratch clone. |

## Summary

courtroom-platform-az is the stronger CI posture (OIDC, environments, SHA-pinned
actions, secret/image scan, gated apply); smalt is the stronger verification
*machinery* (courts, kind/swarm end-to-end proof, substrate-in-CI pattern) but
that machinery never runs in CI on a PR. Highest-leverage closes, in order:
(a) courts on PRs, (d) TFPOSHT_LIVE job in posh-go, (c) access-root plan +
scheduled drift, (b) explicit cross-repo gate contract, then (e)/(f) hygiene.
