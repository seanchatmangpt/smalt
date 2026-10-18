# AZSIM-BURN — v26.10.18 Sovereign Burn-In & Chaos Matrix (Azure enterprise sim)

Status: SPECIFICATION · Standing of every ticket: UNKNOWN until its receipt lands.
Base subject at authoring: `21f58b0` (main). Tickets: [`TICKETS.md`](TICKETS.md).
Receipts: `docs/jira/v26.10.18/burn/` (JSONL, schema AZB-03) +
`docs/jira/v26.10.18/receipts/azb-NN-*.md` (standing lines, real output embedded).

## Intent

v26.10.17 proved per-test isolation (2655/0) but left ~1 timing flake per
full-suite pass under host constraints. v26.10.18 moves reliability proof off the
host into a containerized burn foundry (`docker/burn/`) and models a realistic
multi-tier Azure enterprise as four concurrent **plane profiles** (`config/env/`)
inside the BEAM. No `kind`, no `act`, no cloud egress. No sleeps (NO-SLEEP-DOCTRINE).

## Fence (existing system — preserve, extend, do not replace)

| Existing | Locus | Rule for this epic |
|---|---|---|
| Single all-planes child list | `lib/smalt/application.ex` | `:plane` unset ⇒ `:all` ⇒ byte-identical child list to today |
| Flat port keys `:arm_port` / `:egress_port` / `:mcp_port` / `:arm_tls_port` | `config/config.exs`, `Smalt.Config` (ontology projection `smalt:ck-arm-port`) | Plane profiles set the **existing** keys; new keys go ontology → ggen → `Smalt.Config`, never hand-edited projection |
| Config-time ephemeral ports under `MIX_ENV=test` | `config/test.exs` | Untouched; burn containers rely on netns, test tier relies on this |
| Burn scripts (boot/chaos/soak/matrix/container) | `docker/burn/*.sh`, `compose.burn.yml`, `justfile.d/30-burn.just` | Extend; JSONL rows conform to AZB-03 schema |
| assert_eventually / Notifier / Sweeper one-writer | `rewrite-drafts/assert-eventually.ex.md`, `LRO.Notifier` | All waits route here; zero `Process.sleep` |
| court-x2 | `justfile.d/07-court-x2.just` | Final gate; burn receipts become a precondition, not a substitute |

## Plane topology

```mermaid
flowchart LR
  subgraph identity["az_prod_identity (KeyVault + Entra STS)"]
    KV["KeyVault 7.4 /keys /secrets (TLS 9444)"]
    STS["STS bearer authority"]
  end
  subgraph control["az_prod_control (ARM)"]
    ARM["ARM gateway 9443 strict api-version"]
    GL["graphlaw fail_closed"]
  end
  subgraph data["az_prod_data (Cosmos SQL + Blob hot)"]
    COS["Cosmos SQL AST + If-Match ETag"]
    BLOB["Blob HEAD/GET range, DETS mirrored"]
  end
  subgraph integ["az_prod_integration (Service Bus + Event Grid)"]
    AMQP["AMQP 1.0 5672 SASL anonymous, DLQ"]
    EG["Event Grid at_least_once"]
  end
  STS -->|bearer| ARM
  STS -->|bearer| COS
  STS -->|bearer| BLOB
  ARM -->|resource events| EG
  EG --> AMQP
```

Two deployment shapes, same profiles:
1. **Single node, all planes** (`SMALT_PLANES=control,data,integration,identity`): one BEAM, four isolated supervision subtrees.
2. **Plane-per-container** (burn matrix): one netns per plane, canonical ports (9443/8443/5672) with zero collision.

## Ticket DAG

```mermaid
flowchart TD
  AZB01[AZB-01 image pin] --> AZB02[AZB-02 netns compose]
  AZB03[AZB-03 burn JSONL schema] --> AZB13
  AZB04[AZB-04 plane profile loader] --> AZB05[AZB-05 control] & AZB06[AZB-06 data] & AZB07[AZB-07 integration] & AZB08[AZB-08 identity]
  AZB05 & AZB06 & AZB07 & AZB08 --> AZB09[AZB-09 plane supervision subtrees]
  AZB09 --> AZB10[AZB-10 cross-plane wiring]
  AZB10 --> AZB20[AZB-20 SDK interop per plane]
  AZB11[AZB-11 isolation court] --> AZB22
  AZB12[AZB-12 ratio fences] --> AZB22
  AZB02 & AZB09 --> AZB13[AZB-13 boot burn x50]
  AZB13 --> AZB14[AZB-14 SIGKILL + DETS repair]
  AZB09 --> AZB15[AZB-15 subtree DR kills]
  AZB07 --> AZB16[AZB-16 AMQP 4096 saturation]
  AZB14 & AZB15 & AZB16 --> AZB17[AZB-17 parallel plane matrix]
  AZB17 --> AZB18[AZB-18 cgroup soak]
  AZB13 --> AZB19[AZB-19 pipeline overlap]
  AZB21[AZB-21 zero-sleep gate] --> AZB22
  AZB18 & AZB19 & AZB20 --> AZB22[AZB-22 burn ring 50-cycle green]
  AZB22 --> AZB23[AZB-23 court-x2 frozen tree]
  AZB23 --> AZB24[AZB-24 release receipt + standing]
```

## Release gate (v26.10.18)

| # | Invariant | Machine check | Ticket |
|---|---|---|---|
| G1 | 0 unclassified `Process.sleep` in `lib/` + `test/` | `just sleep-gate` exit 0 + seeded-sleep mutation refused | AZB-21 |
| G2 | Burn matrix 4 planes × N containers × 50 cycles: 0 orphans, 0 unhandled exceptions, 100% receipts | `just burn-ring` + `validate_burn.py --gate` | AZB-22 |
| G3 | court-x2 two consecutive green on frozen quiescent tree | `just court-x2` judge log | AZB-23 |
| G4 | Isolation court: 0 unguarded `Application.put_env`, 0 unsupervised singletons | `just isolation-court` | AZB-11 |
| G5 | Every unmodified SDK lane green against its plane profile | `just azsim-sdk` | AZB-20 |

Close condition: honest all-green or honest typed RED (`broken_term` from the
Chatman table). Never a faked pass; a single burn row missing ⇒ `R_missing_consequence`.
