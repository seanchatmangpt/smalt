# SM3 receipt

Standing: UNVERIFIED

Subject: smalt Key Vault certificates + Log Analytics parity gaps mirroring arcus AX1.
Authored statically; mix, tests, git not run. Compile unverified.

Files (new): lib/smalt/azure/kv_certificates.ex (policy get/update, attribute update,
import, versions), lib/smalt/azure/log_analytics.ex (ingest, table list/get),
test/smalt/azure/sm3_parity_test.exs (real Store rows, no mocks).
Not wired into EgressRouter; existing certs create/get/delete/backup/issuers untouched.
Uncovered: router routes, real multi-version history, full KQL.
