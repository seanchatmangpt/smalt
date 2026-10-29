# w6bi — ERROR_CODES wave-6 regen + extractor families

**Standing:** ALIVE (module tier)
Context: solo
Date: 2026-10-20

Directive: regenerate docs/ERROR_CODES.md over wave-6 literals; extend extractor families for misses; verify --check; sample-verify rows. No commits.

## Changes (scripts/gen_error_codes.py only; zero lib/ edits)

1. Egress `in_helper_def`: `defp` → `defp?` — public `def` envelope helpers (check_akv_api_version, check_sentinel_api_version, invalid_eg1_event_error) now skipped from send-pairing; their codes ride the pinned helper list. Clears the 3-site UNRESOLVED_STATUS fail-closed exit that blocked generation on lane start.
2. T7 pins (fail-closed): GroupExists 409, GroupNotFound 404, SchemaNotFound 404, InvalidSchema 400, InvalidFeatureFlag 400, InvalidFeatureFlagName 400.
3. eh_schema_registry.ex added to the T7 scan sources (messaging/, not data_plane/).
4. ARM families (new extract_arm_modules()):
   - T9: send_arm_error both forms (plain + ctx callback), literal status+code.
   - T10: {:error, {:atom, "Code", msg}} atom-pinned tuples — ARM_TUPLE_STATUS {bad_request:400, not_found:404, conflict:409, precondition_failed:412}, fail-closed on unknown atom.
   - T11: ARM_PINNED_ENVELOPES — InvalidResourceNamespace 400 (resource_providers @doc + witness), RoleDefinitionDoesNotExist 400 (rbac consumer mapping).

## Real output

```
$ python3 scripts/gen_error_codes.py
wrote /Users/sac/smalt/docs/ERROR_CODES.md (241 rows)
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
CHECK-OK
$ git diff --stat docs/ERROR_CODES.md
 docs/ERROR_CODES.md | 356 ++++++++++++++++++++--------
 1 file changed, 221 insertions(+), 135 deletions(-)
```

Row growth: 207 → 241 (+34 rows).

## Sampled literals (15 sampled; directive asked 10)

Present as table rows: ContainerLocked (3), ImmutabilityPolicyNotFound (2), InvalidApiVersion (3), InvalidQueryParameterValue (3), ConsumerGroupConflict, ConsumerGroupNotCreatable, GroupExists, GroupNotFound, SchemaNotFound, InvalidSchema, InvalidFeatureFlag, FacetRequestNotSupported, ManagedStorageAccountNotRegenerated, MalformedBackupBlob, RoleDefinitionDoesNotExist (2), InvalidResourceNamespace, LeaseAlreadyPresent, PopReceiptMismatch, MessageNotFound, SnapshotNotFound — 14 sampled unique + others.

Typed out-of-scope (1): ForwardChainLimit (queue_store.ex:364) — annotation-only dead-letter reason (x-ms-annotation), carries no HTTP status; out of the doc's status+code row contract. Would need a new surface taxonomy for annotation-class codes. Typed residual, not a miss. Noted for the parent.

## Falsifier

The fail-closed exits are the falsifier's teeth: the generator exited 1 three times during this lane (UNRESOLVED_STATUS ×1, T7-unpinned ×2) rather than shipping a guessed status. If `--check` drifts while claiming pass, or any sampled literal greps 0 as a table row, this receipt is vacuous — re-run and re-mint.

## Disclosures

- First Write of this receipt hit the wave's large-Write corruption class mid-write (12+ lanes hit this wave; all self-caught). This clean rewrite is verified by the read-back rule: the file now holds exactly this short body.
- No lib/ edits — extractor-only. No commits.
- Out of scope, one line: several wave-6 lanes are still authoring; their literals will need another regen pass at integration (the regen window is rolling).
