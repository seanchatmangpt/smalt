# Enclave Testbed (v26.10.14)

Fortune-5 enclave-grade composite stress testbed for smalt's most
complex/costly Azure service classes, exercised TOGETHER on one live
substrate:

1. **SKR** — Secure Key Release: MAA attestation, HKDF release material,
   jti single-use replay refusal (`Smalt.DataPlane.SKR`)
2. **WORM** — legal hold + locked immutability policy + retention expiry
   via injected clock (`Smalt.DataPlane.BlobStorage`)
3. **Confidential Ledger** — append, dup-409, Merkle chain verify, tamper
   detection (`Smalt.Security.ConfidentialLedger`)
4. **Purview/Atlas** — entities + 2-hop lineage (`Smalt.DataPlane.PurviewAtlas`)
5. **Sentinel** — DCR ingest, strict-mode creation marker, KQL query
   (`Smalt.DataPlane.Sentinel`)
6. **Resource Graph** — typed 400s for hostile shapes
   (`Smalt.DataPlane.ResourceGraph`)
7. **Cosmos at scale** — 500-doc container, cross-partition query +
   >100-doc continuation walk (`Smalt.DataPlane.Cosmos`)
8. **ARM LRO** — 50 background PUTs, at-rest sweeper convergence
   (`Smalt.ArmGateway.LRO.Sweeper`)
9. **Service Bus** — session lock exclusivity + DLQ properties under EH load
10. **Event Hubs** — producer/consumer contention, CAS checkpoint race

Plus a chaos overlay: the LRO sweeper child is killed mid-run; the
supervisor restart must restore service while the substrate keeps serving.

## Run

```sh
bash test/enclave-testbed/run.sh
```

`run.sh` takes the EXCLUSIVE `/tmp/smalt-substrate.lock` (single substrate
per host), boots the substrate via `mix run test/enclave-testbed/
enclave_testbed.exs` (which starts `Smalt.Application`), then tears it
down. Log: `tmp/enclave-testbed.log`. Exit 0 = all phases PASS.

Phases assert hard — refusals that are the law (WORM 409, TokenReplay 403,
forged continuation 400, DLQ property stamps) assert against the exact
error envelope, never a bare 2xx. A lib defect is FILED in
`docs/jira/v26.10.14/sdk-results/enclave-testbed.md`, never patched here.
