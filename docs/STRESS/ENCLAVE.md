# ENCLAVE — Composite High-Assurance Testbed

| field | value |
|---|---|
| driver | `test/enclave-testbed/enclave_testbed.exs` |
| runner | `test/enclave-testbed/run.sh` (dedicated substrate, private ports 29440-29444, lock `/tmp/smalt-substrate-enclave.lock`) |
| how to rerun | `bash test/enclave-testbed/run.sh` — exit 0 = all phases PASS |
| log | `tmp/enclave-testbed.log` |
| latest receipt | `docs/jira/v26.10.14/sdk-results/enclave-testbed.md` (2026-10-15: 9/9 PASS; ENCLAVE-1 RESOLVED-INVALID — disposition in receipt) |
| build root | `MIX_BUILD_ROOT=_build-enclave` (warm ≈ 75-140 s full run) |

Ten high-assurance service classes exercised TOGETHER on one live
substrate (full `Smalt.Application` boot): SKR attestation→release→jti
replay, WORM legal hold + locked immutability + retention expiry (injected
clock), Confidential Ledger Merkle chain verify + tamper detection,
Purview/Atlas lineage, Sentinel DCR ingest→strict-mode marker→KQL,
Resource Graph typed 400s, Cosmos 500-doc cross-partition continuation
walk, 50× ARM LRO + at-rest sweeper convergence, Service Bus session
exclusivity + DLQ properties, Event Hubs producer/consumer contention with
CAS checkpoint races — plus a chaos overlay (LRO sweeper child killed
mid-run; supervisor restart must restore service).

Every refusal that is the law (WORM 409, TokenReplay 403, forged
continuation 400, second session claim `:already_locked`, CAS conflict
exactly-once) is asserted against the exact error envelope, never a bare
2xx. A lib defect is FILED in the receipt, never patched in the driver:
ENCLAVE-1 (put_blob CREATE path bypasses `worm_blocked?/3` — legal hold
does not block creating a new blob) is currently the one open finding.
