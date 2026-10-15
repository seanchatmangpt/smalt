# R1 Input Fuzz Findings — 2026-10-15T04:44:31.263Z

- Total fuzzed requests executed: 0
- Findings: 0
- By kind: {}

## Confirmed crash classes (server stack traces witnessed in substrate.log)

1. wrap_json_list/1 FunctionClauseError — lib/smalt/egress_router.ex:683 (call site :289). POST /dataCollectionRules/:dcr/streams/:stream with a JSON OBJECT body lacking "_json" (or empty body with application/json) -> HTTP 500 empty body.
2. ConfidentialLedger.canonical/1 Protocol.UndefinedError on %Plug.Conn.Unfetched{} — lib/smalt/security/confidential_ledger.ex:116 (call site egress_router.ex:103). POST /app/transactions with non-JSON content-type (application/xml, text/plain) -> 500.
3. Cosmos.quoted_sha256/1 Jason.Encoder Protocol.UndefinedError on %Plug.Conn.Unfetched{} — lib/smalt/data_plane/cosmos.ex:280 (call site egress_router.ex:115). POST /dbs/:db/colls/:coll/docs with non-JSON content-type -> 500.
4. Bandit HTTP-layer rejections (413/414/431) and 10MB-body connection resets (ECONNRESET/EPIPE) on DELETE/PUT routes that never read the body: fail-closed but NOT JSON error envelopes.
5. Cosmos 404 bodies use the Azure-documented {"code":...} shape (no error.code envelope) — flagged BAD-ERROR-ENVELOPE by the strict invariant, accepted as documented shape.
