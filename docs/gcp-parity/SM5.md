# SM5 Receipt

Standing: UNVERIFIED

Lane SM5: reconcile WIRE_PARITY, KD-GCP candidates, sdk_coverage rows. No commands executed
(no go/mix/just/pytest/python gate run); edits only.

- docs/gcp-parity/KD-GCP-CANDIDATES.md: header now states rows merged into
  docs/jira/v26.10.14/KNOWN_DIVERGENCES.md lines 378-382 (observed by grep).
- docs/WIRE_PARITY.md: GCP and AWS rows cross-reference the merged KD rows and coverage rows.
- scripts/sdk_coverage.py: added SURFACES rows `gcp`, `aws` with missing_kd registering
  ts/py cells to KD-GCP-05 / KD-AWS-03 (MISSING-REGISTERED). Not run; coordinator should
  run `python3 scripts/sdk_coverage.py`.
