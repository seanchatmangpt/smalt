# Gap 62 — ONE Canonical Onboarding Path (docs lane)

Status: ALIVE (canonical path copy-paste-tested this session; all other POSH docs
demoted to pointers). Parent analysis: `gaps/12-runbook.md` (G12-1..G12-10);
this gap lands the single-path fix G12-1/5/6/8/10 asked for.

## 1. Designation

**Canonical path: `README.md` § "POSH — Go adapter membrane" (Quickstart block).**
Every other onboarding doc is now a pointer to it, not a second copy of the path.

Canonical block (4 lines, each independently pasteable — verified, see §3):

```sh
colima start
just posh-doctor
just posh-court
just posh-status
```

## 2. Drift table (audit of all operator-facing POSH docs)

Sources audited: `README.md` §POSH, `posh/README.md`,
`adapters/terraform-provider-smalt/README.md`, `examples/README.md`,
`gaps/12-runbook.md`, `dfcharter/define.md`,
`docs/jira/posh/v26.10.30/{README,working-backwards}.md`,
`justfile.d/58-posh.just`, `justfile.d/52-kind.just`, `k8s/kind-config.yaml`.

| # | Doc | Command(s) taught | Drift found | Disposition |
|---|---|---|---|---|---|
| D1 | README.md §POSH (pre-edit) | `make -C posh build`, `just posh-court` + ordering contract list | Named only 2 commands, then a bare ordering list; prereqs separate; no doctor/status witness; line-wrapped fenced comment would break line-paste | **Canonical** — rewritten as 4-line tested block |
| D2 | posh/README.md | `make build`, `make test`, boot+echo python walk (uses `sleep 1`, manual `pkill`) | Membrane-only echo path taught with no link to the court path; `sleep 1` is a fixed wait | Pointer added; echo walk kept as membrane debug (not operator path) |
| D3 | adapters/terraform-provider-smalt/README.md | manual `kind create cluster --config k8s/kind-config.yaml` + `docker build` + `kind load` + secret/apply burn; `export TF_CLI_CONFIG_FILE=.../dev.tfrc` | Second full kind burn duplicating the justfile ladder; historically mismatched cluster name (G12-2: config was `kind-smalt` vs `--name smalt`); its dev.tfrc is a **different rc file** from the court's `tmp/posh/tfrc` | Pointer added; manual walk kept for piece-by-piece debugging; cluster-name drift already resolved (kind-config.yaml:19 `name: smalt` = `SMALT_KIND_CLUSTER` default) |
| D4 | examples/README.md | `bash examples/quickstart.sh`, `python3 examples/python_client.py`, `scripts/substrate-ctl` | Prereqs taught only the BEAM path (`mix compile`/`bootstrap.sh`), silent on the kind plane the POSH examples need (G12-8); `substrate-ctl` is the host-BEAM substrate, a third substrate identity | Pointer added in Prerequisites; host-BEAM framing made explicit |
| D5 | gaps/12-runbook.md | (analysis, no commands) | Prescribed ordering `colima → kind-up → kind-images → kind-deploy → court` — correct but scattered across a gap analysis, not an operator doc | Historical parent analysis; superseded by README §POSH for operators |
| D6 | dfcharter/define.md | (none — charter, no commands) | No drift; boundary rules consistent with canonical path | No change |
| D7 | working-backwards.md:57-58 | "health assert /metadata/endpoints 200" | G12-3 already fixed pre-session (readiness anchor, /healthz 401 noted) | No change |
| D8 | 58-posh.just:238 posh-smalt-wire SKIP message | "boot with: just kind-up && kind-images && kind-deploy" | G12-4 already fixed pre-session (was `just substrate-up`) | No change |
| D9 | README.md §POSH pre-edit landmines | — | — | Landmines (healthz 401, TF 1.14 dev_overrides form, cluster-name pin, 20GB disk fence / `just kind-prune`) folded into canonical section |

## 3. Copy-paste test (receipt)

Extracted every fenced `sh` line from the canonical section
(`awk '/## POSH — Go adapter membrane/,/## See Also/'`), for each line:
comment → skip; `just X` → `just --list --unsorted | grep -q " X "`; bare
binary → `command -v`. First pass caught a real defect: a wrapped comment
continuation line inside the fenced block read as a command and would fail a
line-by-line paste — fixed by shortening comments so every fenced line is a
complete command. Final result:

```
colima start      -> OK-binary (command -v colima)
just posh-doctor  -> OK-recipe (just --list)
just posh-court   -> OK-recipe (just --list)
just posh-status  -> OK-recipe (just --list)
```

`posh-court` pre-stage embeds kind-up/kind-images/kind-deploy + posh-build +
posh-install (58-posh.just:348), so the 4-line path is genuinely minimal.

## 4. Read-only spot tests (3)

1. `just posh-status` — ran live: exit 0; Makefile present, provider binary
   built (25M), transient rc at tmp/posh/tfrc, example root present,
   **metadata anchor OK** (curl /metadata/endpoints → 200 JSON). Plane answering.
2. `kind get clusters` — `athena`, `smalt` present. Cluster-name drift
   (G12-2) confirmed resolved: kind-config.yaml:19 `name: smalt` and
   52-kind.just:71 `--name {{SMALT_KIND_CLUSTER}}` (default `smalt`) agree.
   The manual adapter-README burn now produces the same cluster name.
3. `make -C posh` target existence + `command -v` for the full prereq set
   (just/make/go/terraform/kind/kubectl/colima all on PATH); `posh/Makefile`
   present; referenced files (`examples/quickstart.sh`, `scripts/bootstrap.sh`,
   `verification/py/run.sh`) all exist.

## 5. Standing

- **ALIVE**: canonical README §POSH rewritten and copy-paste-tested (§3-4);
  pointers in posh/README, adapters/terraform-provider-smalt/README,
  examples/README.
- PARTIAL (noted, not fixed here): posh/README echo walk retains `sleep 1`
  (no-sleep-doctrine residue in a doc example); adapter README's dev.tfrc
  path (`adapters/.../dev.tfrc`) vs court rc (`tmp/posh/tfrc`) are two rc
  files of the same content class — both use the lawful TF 1.14 form.
- Close condition for full closure: `just posh-doctor` gains a
  docs-consistency assertion (pointers present, no second quickstart teaches
  a conflicting cluster name), or `just posh-runbook-check`.
