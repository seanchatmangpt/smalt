# KD-GCP Candidates

Standing: PARTIAL

Proposed rows in the posh/KNOWN_DIVERGENCES.md section 5 format. MERGED into docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (rows KD-GCP-01..05, lines 380-384); this file is now a historical candidate record. Covers globs are whitespace-free fnmatch cells.

| ID | Covers (cell globs) | Divergence | Evidence receipt | Close condition |
| :--- | :--- | :--- | :--- | :--- |
| KD-GCP-01 | gcs:buckets,gcs:objects | GCS state lives in a private GenServer, not a `Smalt.Store` table (generated StoreTables registry is out of lane scope); not journaled/restored like Store rows. | docs/gcp-parity/GS1.md | Pack ontology gains a GCS table and engine moves onto it. |
| KD-GCP-02 | secretmanager:*,kms:* | Self-contained Agent state with `:crypto` AES-256-GCM / ECDSA P-256; not bridged to Key Vault tables. | docs/gcp-parity/GS4-secrets-kms-census.md | Engines share Key Vault Store tables or divergence is accepted. |
| KD-GCP-03 | run:services,run:revisions,run:iam | Cloud Run is simulated (no container execution); LROs complete synchronously; URIs are `https://{svc}-{project}.{region}.run.smalt.local`; IAM conditions not evaluated; revision suffix is a template hash, not random. | docs/gcp-parity/GS6.md | Async LRO progression and real URI format adopted, or accepted. |
| KD-GCP-04 | logging:entries.list | Filter language limited to AND of severity, logName, resource.type, textPayload substring; others return 400. No OR/NOT/jsonPayload/timestamp comparison. | docs/gcp-parity/GS6.md | Filter parser covers the documented grammar. |
| KD-GCP-05 | gcp:* | All GCP rows are UNVERIFIED: authored without compile or test run. | docs/gcp-parity/GCP_WIRE_PARITY.md | Coordinator runs `mix test test/gcp` green and records witnesses. |

## Witness map (smalt-15, 2026-11-14)

All rows stay OPEN in KNOWN_DIVERGENCES.md lines 380-384 (file outside this lane's ownership).

| ID | Witness file | Status |
| :--- | :--- | :--- |
| KD-GCP-01 | /Users/sac/smalt/test/gcp/storage_test.exs | OPEN: needs pack-ontology GCS table |
| KD-GCP-02 | /Users/sac/smalt/test/gcp/secrets_kms_secret_manager_test.exs, secrets_kms_kms_test.exs | OPEN: bridge-or-accept pending |
| KD-GCP-03 | /Users/sac/smalt/test/gcp/run_logging_router_test.exs | OPEN: sync LRO, template URIs remain |
| KD-GCP-04 | /Users/sac/smalt/test/gcp/run_logging_test.exs (filter grammar pin) | OPEN: AND-of-four only |
| KD-GCP-05 | Run log in GCP_WIRE_PARITY.md | OPEN: no PASS until a green run is recorded |
