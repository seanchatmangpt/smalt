# Gap 12 — Clone-to-Green Runbook for `just posh-court`

Status: PARTIAL — the ladder itself is fail-closed and self-diagnosing (ALIVE), but the
documented path from a fresh clone to green is fragmentary: no single doc names the
full prereq set, ordering, or cluster-name identity; two README quickstarts disagree
on the cluster name; one doc claims a health endpoint that 401s.

Scope: walk the documented paths vs reality on this machine (2026-10-30). Receipt
basis: direct reads of README.md, posh/README.md, adapters/terraform-provider-smalt/README.md,
examples/README.md, docs/jira/posh/v26.10.30/{README,working-backwards}.md, justfile.d/58-posh.just,
justfile.d/52-kind.just, k8s/{kind-config,smalt-backend}.yaml; live `terraform version` (v1.14.6),
`go version` (1.23.4), `colima status` (running, VZF), `df -h` (119Gi free).

## 1. Reality (what a fresh clone actually needs, in order)

Outline of the missing runbook — headings + one line each, not full text:

1. **Prereqs (none currently collected in one place).**
   - Docker daemon: `colima start` (VZF) — kind-up fails with no typed message if the
     daemon is down; `_check_kind_tools` checks binaries only, not the daemon.
   - Toolchain: go 1.23+, terraform 1.14+, kind, kubectl, curl, just, golangci-lint
     (optional — its absence is a typed stage-1 SKIP, exit 3).
   - ggen + asdf elixir 1.20.4-otp-29 / erlang 29.1.2 only for `posh-generate` (mix
     compile gate) and BEAM tests. Default PATH may resolve Homebrew elixir 1.19.x,
     which mix.exs (`~> 1.20`) refuses — posh-generate already pins
     `$HOME/.asdf/installs/...` explicitly (58-posh.just:162-163); other mix entry
     points do not.
2. **Ordering.** `colima start` → `just kind-up` (creates cluster `smalt` via
   `--name` overriding the config's `name: kind-smalt`) → `just kind-images`
   (disk preflight 20000MB, `just kind-prune` if low) → `just kind-deploy`
   (secret `smalt-release-cookie`, ns `default`) → TLS trust state (`.smalt/tls/ca-cert.pem`
   for the 9444 TLS twin; HTTP 9443 needs none) → `just posh-court` (pre-stage
   re-runs kind-up/images/deploy itself, so steps 2-4 are its internal pre-stage;
   a standalone operator only needs colima + tools).
3. **Identity pins that the court sets for you** (must be documented, they are
   load-bearing): `SMALT_KIND_BACKEND_IMG=smalt:local` (kind default is
   `smalt:hermetic` — witnessed ErrImageNeverPull), TF_CLI_CONFIG_FILE at
   `tmp/posh/tfrc`, example root `adapters/terraform-provider-smalt/examples/basic`.
4. **Known landmines** (each already witnessed; runbook collects them):
   - TF >= 1.14 dev_overrides: unlabeled block + attribute form only (provider README:74-79
     documents it; `posh-install` writes the correct form).
   - `/healthz` is bearer-gated (401); readiness probe is `/metadata/endpoints` (always-200).
   - api-version ceilings: resourcegroups admits only `2023-07-01` via the registry gate;
     containerApps list `2024-03-01`.
   - kind node disk: `kind-images` fails closed below 20000MB on /var/lib/containerd
     after prune; `just kind-prune` standalone.
   - Pod CrashLoop classes: stale `smalt-release-cookie` secret (must be (re)created
     before apply), ErrImageNeverPull on tag mismatch.
   - Host disk: the kind node fence is 20GB; host-level exhaustion surfaced as the W-D
     incident (52-kind.just header).
5. **BEAM-side caveat** (only if the operator also runs Elixir tests/posh-generate):
   asdf elixir 1.20.4-otp-29, not the Homebrew 1.19.5 default.

## 2. Doc-gap table

| # | Location | Missing / wrong / stale | Reality | Close condition |
|---|---|---|---|---|
| G12-1 | README.md:447-453 (POSH Quickstart) | Says `make -C posh build` + `just posh-court` is the whole quickstart; no prereqs, no colima, no ordering | Fresh clone without colima/kind/TF fails at court pre-stage | Rewrite quickstart as the runbook outline in §1; link it from README.md:453 |
| G12-2 | adapters/terraform-provider-smalt/README.md:39-43 | Manual quickstart boots `--name kind-smalt` (matching kind-config.yaml:19); no `--name` flag is given on create; secret create command shown but posh-court/kind-deploy may differ | `just kind-up` passes `--name smalt` (52-kind.just:71, default `SMALT_KIND_CLUSTER=smalt`) which overrides the config — two documented boot paths yield differently-named clusters; `kind load --name kind-smalt` then loads into the wrong cluster under the justfile path | Pick one canonical name; either set `SMALT_KIND_CLUSTER=kind-smalt` in 58-posh.just or change kind-config.yaml name + README to `smalt`; assert `kind get clusters` in posh-doctor |
| G12-3 | docs/jira/posh/v26.10.30/working-backwards.md:52 | "health assert /healthz 200" | `/healthz` is bearer-gated (401); the court polls `/metadata/endpoints` (58-posh.just:284) | Update line to metadata-anchor readiness; add a one-line errata |
| G12-4 | justfile.d/58-posh.just:246 (`posh-smalt-wire` SKIP message) | "boot with: just substrate-up" — that boots the host BEAM substrate (01-substrate-lock.just:12), not the kind plane the court uses | The lawful fix for stage-5 SKIP inside the court is the kind ladder, not substrate-up | Change message to "run via just posh-court pre-stage (kind-up/kind-images/kind-deploy)" |
| G12-5 | (absent) | No doc collects the prereq set: colima, go 1.23, terraform 1.14+, kind, kubectl, golangci-lint (optional), ggen+asdf 1.20.4 (generate/BEAM only) | `_check_posh_tools` checks only go/terraform/kubectl/curl; `_check_kind_tools` checks kind/kubectl/docker; nothing checks the docker daemon | Add a "Prerequisites" section to docs/jira/posh/v26.10.30/README.md (or a new gaps/12 appendix) listing all, with install commands |
| G12-6 | (absent) | No ordering contract colima → kind-up → kind-images → kind-deploy → secret → court | posh-court embeds the kind ladder so ordering is implicit; a fresh operator running pieces manually has no doc | One ordered block in the runbook; note that `just posh-court` alone is sufficient when prereqs are met |
| G12-7 | (absent) | Disk landmines: 20000MB node fence, W-D host-disk incident, `just kind-prune` | Documented only in 52-kind.just comments (52-kind.just:22-24) | Runbook "Landmines" section; link `just kind-prune` |
| G12-8 | examples/README.md:8-13 | Prereqs say "smalt repo built at least once (mix compile / bootstrap.sh)" — not sufficient for posh-court examples; no kind/colima/TF mention | examples/basic needs the kind plane + dev_overrides rc, not mix artifacts | Add a pointer to the POSH runbook from examples/README.md Prerequisites |
| G12-9 | docs/jira/posh/v26.10.30/README.md (index) | No row for a runbook/ops doc; `dfcharter/verify.md` is "PLANNED — rungs... not yet"; gaps/ has only 03 (now 03+12) | — | Add runbook row; flip verify.md from PLANNED when the court campaign receipts land |
| G12-10 | posh/README.md | Good standalone membrane quickstart, but silent on the court context (no pointer to `just posh-court` prereqs) | — | One "See also: clone-to-green runbook" line |

## 3. What is already green (no gap)

- The ladder itself: fail-closed, typed `[POSH-*]` exits, exit contract 0/1/3
  (58-posh.just:37, 282-...), bounded polls not sleeps for readiness (60x1s),
  SKIP-only-when-loud for golangci-lint / example-root / substrate.
- dev_overrides handling: transient rc at tmp/posh/tfrc, never ~/.terraformrc;
  correct TF 1.14 attribute form written by both posh-install and
  adapters scripts/dev_overrides.sh.
- Landmine documentation that exists and is accurate: provider README troubleshooting
  table (healthz 401, api-version 2023-07-01 ceiling, ca_cert PEM, NodePort 9443→30943);
  k8s/README.md burn; SMALT_KIND_BACKEND_IMG pin rationale (58-posh.just:285-288).

## 4. Standing

ALIVE: this gap analysis (doc reads + live tool checks this session). PARTIAL: the
clone-to-green story — the court is self-diagnosing but the documented path is
fragmentary; G12-1/2/5/6 are the four gaps that would actually stop a fresh operator
(cluster-name identity G12-2 being the only one that can silently mislead). Close
condition for the whole gap: `just posh-doctor` (or a new `just posh-runbook-check`)
asserts prereqs (incl. docker daemon), cluster-name identity, and rc presence, and
README quickstart points at it.
