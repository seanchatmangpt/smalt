# 56 Bootstrap Landing

Lane 3/16 (v26.10.30 wave) — clone-to-green staged recipe `just posh-bootstrap`,
landed in `justfile.d/58-posh.just` (appended after `posh-regen-check`).

## What Landed

- `posh-bootstrap` recipe, 8 resumable stages, each idempotent with a typed
  `[BOOTSTRAP-n] PASS / SKIP(reason)` line:
  - **S1 tools** — delegates blocking checks to `posh doctor` when
    `posh/bin/posh` exists; typed PATH loop (`go/terraform/kubectl/curl`)
    fallback otherwise.
  - **S2 deps** — `go mod download` over `posh/` and the provider dir
    (`SMALT_POSH_PROVIDER`, env-pinned to `adapters/terraform-provider-smalt`);
    `mix deps.get` ONLY under `POSH_BOOTSTRAP_BEAM=1`, loud SKIP otherwise
    (pinned asdf toolchain PATH, mirroring posh-generate).
  - **S3 kind** — `just kind-up kind-images kind-deploy` with
    `SMALT_KIND_BACKEND_IMG=smalt:local` pinned (ErrImageNeverPull witness);
    SKIP when cluster `smalt` exists AND all nodes report ` Ready`.
  - **S4 images** — SKIP when `smalt:local` is loaded in the node containerd
    (`docker exec smalt-control-plane crictl ... imgi`); `docker images`
    fallback when the node container is unreachable.
  - **S5 deploy** — SKIP when pod `smalt-backend-0` reports a ready container
    status; otherwise `just kind-deploy`.
  - **S6 health** — bounded poll 60x1s on the ARM metadata anchor
    (`SMALT_POSH_META`, bearer-EXEMPT — the discriminator-correct plane;
    `/healthz` is bearer-gated 401 and would false-negative forever).
  - **S7 provider** — `just posh-build` + `just posh-install`; SKIP when the
    binary is fresh (binary mtime newer than every `.go`/`go.mod`/`go.sum`).
  - **S8 example** — OPTIONAL apply+destroy of
    `adapters/terraform-provider-smalt/examples/basic` under
    `POSH_BOOTSTRAP_APPLY=1` only, behind `scripts/guard_local_apply.sh`
    first (GAP6(b) fence) and the transient dev_overrides rc.
- Stage selection: `POSH_BOOTSTRAP_STAGES` (default `all`; comma/space subset
  of S1..S8) — unselected stages emit a loud typed SKIP line.

## Witnessed Partial Run (2026-10-30)

`POSH_BOOTSTRAP_STAGES=S1,S2,S7 just posh-bootstrap` — exit 0 (lane 38 holds
the substrate mid-court; S3-S6+S8 typed `SKIP(observed-by-lane-38)`):

```text
[BOOTSTRAP-1] PASS tools (posh doctor blocking checks green)
[BOOTSTRAP-2] PASS go mod download (posh)
[BOOTSTRAP-2] PASS go mod download (adapters/terraform-provider-smalt)
[BOOTSTRAP-2] SKIP mix deps.get (POSH_BOOTSTRAP_BEAM unset — BEAM tests not requested)
[BOOTSTRAP-3] SKIP(observed-by-lane-38: substrate held mid-court; stage filtered)
[BOOTSTRAP-4] SKIP(observed-by-lane-38: stage filtered)
[BOOTSTRAP-5] SKIP(observed-by-lane-38: stage filtered)
[BOOTSTRAP-6] SKIP(observed-by-lane-38: stage filtered)
[BOOTSTRAP-7] SKIP provider binary fresh (adapters/terraform-provider-smalt/terraform-provider-azurerm newer than all Go sources)
[BOOTSTRAP-8] SKIP(stage filtered: not in POSH_BOOTSTRAP_STAGES=S1,S2,S7)
[BOOTSTRAP] result: stages=[S1,S2,S7] green
```

The S7 SKIP is the resumability witness: the goal state (fresh binary) already
held, so the stage skipped itself instead of rebuilding.

## Gates

| Gate | Result |
| ---- | ------ |
| `just --evaluate` | exit 0 |
| `just --summary` parses `posh-bootstrap` | exit 0 |
| Partial run `POSH_BOOTSTRAP_STAGES=S1,S2,S7` | exit 0, green |

## Standing

ALIVE (recipe lands + partial execution green). Full runbook path: fresh clone
-> `just posh-bootstrap` (default all stages) -> `just posh-court` for the
7-stage DoD ladder. Close condition for the full clone-to-green claim: a run
with S3-S6 unfiltered on a substrate lane handoff.
