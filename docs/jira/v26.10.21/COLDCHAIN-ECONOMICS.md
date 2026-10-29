# Case-Study Economics Annex: Cold-Chain GxP Verification — Conventional Azure PaaS vs Sovereign Substrate

Standing: OPERATOR-CHARTER — Azure-side figures are OPERATOR-ASSERTED market rates (no Azure billing receipt exists in this repo); substrate-side figures are MEASURED where annotated
Context: full · Companion to COLDCHAIN-CASE-STUDY.md · Date: 2026-10-21

## 1. The Conventional Azure PaaS Implementation (the "Enterprise Architecture" tax)

Five billing silos for one GxP verification workflow:

| Silo | Services | Operator-asserted run-rate |
|---|---|---|
| Ingress & routing | IoT Hub / Event Hubs Dedicated + APIM Premium | $33,540 + $21,600 /yr |
| Streaming & staging | Stream Analytics / Functions + ADLS Gen2 transactions | (in silo totals) |
| Analytical engine | Synapse / Databricks DBUs (~$15k/mo) | $180,000 /yr |
| State storage | Cosmos DB multi-master, 10–50k RU/s floors (~$2,920/mo) + Service Bus Premium 2 MU | $35,040 + $16,248 /yr |
| Audit & governance | Azure Monitor + Log Analytics + Purview (~$2.5k/mo) | $30,000 /yr |

**Annual infrastructure run-rate: ≈ $316,000 – $450,000** (excluding SI fees, validation consultants, 21 CFR Part 11 audit packages).

## 2. Regulatory failure modes (auditor-flagged)

| Vector | Conventional PaaS | Auditor concern |
|---|---|---|
| Ambient SQL | Queries live in notebooks/jobs/ADF | No cryptographic proof the 2 AM run matches the validated master plan |
| Non-determinism | Spark shuffle joins, dynamic partition counts | Subtle output variations run-to-run |
| Release latency | Multi-hop pipeline 3–15 min | Excursion quarantine lags minutes; lot co-mingling risk |
| Log spoliation | Passive Log Analytics | FRCP 37(e)/FRE 902(14) deficiency — truncatable, not self-authenticating |
| 429 drops | Cosmos RU exhaustion under bursts | One dropped batch event corrupts the excursion window |

## 3. The sovereign substrate on Azure Confidential Computing

One Confidential VM (DCesv5, SEV-SNP) running the substrate core (ERTS 17.1.1/OTP 29.1.2): wire interfaces :8443/:5672, Poka-Yoke ingress, ETS plane, GraphLaw + frozen-duckdb in-memory engine (SHACL pre-execution gating, vectorized pushdown, N3 fixed-point), Affidavit provenance sealing to a WORM cold container.

## 4. Executive contrast

| Dimension | Multi-PaaS | Substrate on confidential VM |
|---|---|---|
| Procurement | Consumption-metered invoices | Azure Marketplace Private Offer, decrements MACC |
| Annual infra | **$316k–$450k (asserted)** | **~$18k (asserted)** — two 16-core CVMs + cold blob |
| Verification latency | 3–15 min (asserted) | **1.842 ms** (case-study reference trace; COLD-1 court to re-measure locally) |
| Query integrity | Injection/notebook-drift exposed | Immutable Turtle RDF AST, SHACL-gated |
| 21 CFR Part 11 | Manual vendor audit defense | BLAKE3-hashed receipts, mathematical chain |
| Burst scaling | Cosmos RU ceilings / 429 | Executor error-free past L8192 (PB-3, measured) |
| Exfiltration | Multi-tenant public planes | Zero-egress by construction (airgap court, measured) |

## 5. Measured-vs-asserted ledger (coordinator typing)

**MEASURED (repo receipts)**: 2 µs native point-read / 74 µs settlement (POWLBENCH); 1.04 ms wire p99 (T43); executor error-free past L8192 (PB-3); zero-egress (airgap court); :auto ETS 10–56× (IMPL-3); 1,609 reds/step denominator (PB-2); memory gate 134≤200 words (OBSFENCE); cold-start 1.9 s release / 3.8× vs 500 ms aspiration (T47 — note the CVM boot profile differs and is unmeasured).

**OPERATOR-ASSERTED (no repo receipt)**: all Azure-side dollar figures; the 1.842 ms / 78% zone-map numbers (reference-trace from the case study, re-measurable by COLD-1 against local duckdb); the ~$18k CVM run-rate; CTRT/FRE 902(14) legal standing; TLA+ refinement.

**The honest boardroom claim**: the substrate-side latency/concurrency/audit guarantees are court-measured; the dollar displacement is a market-rate projection that becomes bankable only with a real Azure billing statement on the conventional side and a CVM deployment receipt on ours.
