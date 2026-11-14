# GCP Wire Parity

Standing: UNVERIFIED

Surface inventory across lanes GS1-GS6, derived from lane receipts and census files as of
2026-11-14. The authoring lanes did not run code; the only observed run (76 passed, combined gcp+aws dirs) is not tied to a HEAD, so no cell is PASS and the Run log below is a PENDING placeholder, not evidence. Cell law
(mirrors posh/KNOWN_DIVERGENCES.md section 4): every cell is PASS, a registered divergence
(KD-GCP-nn, see KD-GCP-CANDIDATES.md), or loudly MISSING.

| Lane | Service | Cell | Status | Ref |
| :--- | :--- | :--- | :--- | :--- |
| GS1 | Cloud Storage | buckets, objects, generations, preconditions, compose, resumable, signed URL | UNVERIFIED (authored) | GS1.md |
| GS1 | Cloud Storage | state in private GenServer, not `Smalt.Store` table | registered-divergence | KD-GCP-01 |
| GS1 | Cloud Storage | XML API host-style, IAM, lifecycle | MISSING | GS1-gcs-census.md |
| GS2 | Pub/Sub | topics, subscriptions, pull/ack, ordering | UNVERIFIED (authored) | GS2.md |
| GS2 | Pub/Sub | push subs, exactly-once, schemas, filters, IAM | MISSING | GS2-pubsub-census.md |
| GS3 | Firestore | CRUD, runQuery, commit, transactions | UNVERIFIED (authored) | GS3.md |
| GS3 | Firestore | transforms, cursors, batchGet, listen, aggregation, auth | MISSING (typed UNSUPPORTED) | GS3-firestore-census.md |
| GS4 | Secret Manager | secrets, versions | UNVERIFIED (authored) | GS4.md |
| GS4 | Cloud KMS | keys, versions, encrypt/decrypt, sign | UNVERIFIED (authored) | GS4.md |
| GS4 | Secret Manager/KMS | self-contained Agent state, not bridged to Key Vault tables | registered-divergence | KD-GCP-02 |
| GS5 | Identity/IAM | `ya29.` token mint, host-keyed router | UNVERIFIED (authored) | GS5.md |
| GS6 | Cloud Run v2 | services CRUD + LRO, revisions, ingress, invoker IAM | UNVERIFIED (authored) | GS6.md |
| GS6 | Cloud Run v2 | HTTP router (REST paths) | MISSING | GS6.md wiring |
| GS6 | Cloud Run v2 | jobs, executions, traffic split, IAM conditions | MISSING | GS6-run-census.md |
| GS6 | Cloud Logging | entries.write, entries.list (filter subset) | UNVERIFIED (authored) | GS6.md |
| GS6 | Cloud Logging | sinks, metrics, buckets, full filter language | MISSING | KD-GCP-04 |

Gate: a `scripts/gcp_coverage.py` modeled on `scripts/sdk_coverage.py` is MISSING; until it
exists this table is hand-derived and carries no mechanical non-vacuity guarantee.

## Run log

Standing: UNVERIFIED

| Date | Command | Exit | Count | HEAD | Recorded by |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 2026-11-14 | gcp test dir run (see ticket smalt-15 acceptance) | PENDING | PENDING | PENDING | coordinator fills from the live run |

An earlier session observed 76 passed for the combined gcp+aws dirs, not tied to a HEAD; it is
not a GCP-only receipt and no count is recorded here until observed.
