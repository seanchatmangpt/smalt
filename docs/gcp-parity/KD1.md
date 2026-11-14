# KD1 Divergence Register Merge

Standing: UNVERIFIED

Authored by edit only; no mix/just/git run. Files re-read after edit.

Rows added to `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical register, 7-column
format, all OPEN): KD-GCP-01, KD-GCP-02, KD-GCP-03, KD-GCP-04, KD-GCP-05, KD-SQ2, KD-AWS-01,
KD-AWS-02, KD-AWS-03. `posh/KNOWN_DIVERGENCES.md` (Azure provider face) untouched.

`docs/WIRE_PARITY.md`: 48 retired test paths (test/compliance, test/amqp, test/wire, and other
retired top-level files) remapped by surface to live files; remap note added to header;
Functions, GCP, AWS rows added to the surface map. Remap is surface-nearest, not
test-for-test equivalence; live files not re-run.

Open: `docs/gcp-parity/KD-GCP-CANDIDATES.md` still says "not merged" (not in KD1 owned set).
