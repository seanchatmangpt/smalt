# KD-135 / KD-136 / KD-138 — registrar closures (lane KD-REG)

- **Date**: 2026-10-22
- **Standing**: PASS
- **Context**: solo
- **Scope**: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md rows KD-135, KD-136, KD-138 only.
  All three were already CLOSED-WITH-RECEIPT (landed via d7ee7222 / 9b7c388a wave);
  this lane re-verified each close condition on the CURRENT tree and appended a
  registrar re-verification clause to each row. No status flips were faked: KD-135
  keeps CLOSED-WITH-RECEIPT (witness-gated), KD-136/138 keep CLOSED-WITH-RECEIPT
  (pinion-closure class, no shim owed).

## KD-135 — Blob DELETE vs WORM-by-default (CLOSED-WITH-RECEIPT, witness-gated)

Close condition: SDK-expressible delete path witnessed end-to-end by a wire witness
postdating any shim. Verified:

- Shim arms still present on current tree:
  ```
  $ grep -n "KD-COVERS: KD-135" lib/smalt/data_plane/blob_storage.ex lib/smalt/egress_router.ex
  lib/smalt/data_plane/blob_storage.ex:177:        # KD-COVERS: KD-135 — engine default follows wire parity: a container
  lib/smalt/egress_router.ex:1368:          # KD-COVERS: KD-135 — Azure parity (official-SDK grounding): a
  ```
- Shim landing commit d577e71e (chore(testbed): B-XML/B-KD blob error face + census
  instrument rows) predates witness commit ccb575b6 (2026-10-21 10:44:14 -0700).
  Shim mtimes at witness time were 2026-10-21 10:23/10:24 (recorded in the witness
  header) vs receipt mtime 10:35 — kd_flip mtime gate satisfied.
- Witness receipt on disk:
  ```
  $ ls -la docs/jira/v26.10.20/receipts/bkd-kd135-137-139-witness.md
  -rw-r--r--@ 1 sac staff 2281 Oct 21 10:35 docs/jira/v26.10.20/receipts/bkd-kd135-137-139-witness.md
  ```
- Witness content (docs/jira/v26.10.20/receipts/bkd-kd135-137-139-witness.md,
  Standing ALIVE, Context pair): default-container Put Container 201 → Put Blob 201
  → Delete Blob **202 Accepted**, no WORM 409; 3 faces / 3 PASS / 0 FAIL.

Note: lib file mtimes are now 2026-10-22 (concurrent lane edits to those files), but
the KD-135 shim arms themselves landed 2026-10-21 10:23/10:24 (commit d577e71e) and
the witness postdates THAT landing — the mtime gate is shim-landing-vs-witness, not
whole-file mtime. No re-witness owed.

## KD-136 — versionless blob GET 400 MissingXMsVersion (CLOSED-WITH-RECEIPT, pinion class)

Close condition: parity pinion citing real-Azure authority + existing census witness.
Verified on disk:

```
$ grep -o '"shape":"[A-Za-z]*"' popcorn_demo/azurite-spike/error-census.jsonl | sort | uniq -c
   3 "shape":"BlobNotFound"
   3 "shape":"ContainerAlreadyExists"
   3 "shape":"ContainerNotFound"
   3 "shape":"InvalidBlobOrBlock"
   3 "shape":"InvalidMetadata"
   3 "shape":"InvalidQueryParameterValue"
   3 "shape":"InvalidRange"
   3 "shape":"MissingContentLength"
   3 "shape":"MissingRequiredHeader"
   3 "shape":"MissingXMsVersion"
```

MissingXMsVersion rows present (census W30-D, 2026-10-21). The row's disposition is a
real-Azure parity pinion (`x-ms-version` required on non-SAS requests per
learn.microsoft.com versioning-for-the-azure-storage-services); smalt's 400 IS the
real-Azure contract; azurite-with-skipApiVersionCheck was the mis-configured leg.
Pinion-closure class: no shim, so no post-shim witness owed. Status stands.

## KD-138 — bogus ?comp= → 400 InvalidQueryParameterValue (CLOSED-WITH-RECEIPT, pinion class)

Same census on disk: 3 InvalidQueryParameterValue rows (see output above). Disposition
is a real-Azure parity pinion (common-rest-api-error-codes: invalid query parameter
value → 400 InvalidQueryParameterValue; `comp=bogus` names no documented operation).
Pinion-closure class: no shim, no witness owed. Status stands.

## Verdict

| row | close condition | evidence on disk | status |
|---|---|---|---|
| KD-135 | SDK-expressible delete witnessed post-shim | bkd-kd135-137-139-witness.md (ALIVE, 202 after shim d577e71e) | CLOSED-WITH-RECEIPT (confirmed) |
| KD-136 | real-Azure parity pinion + census witness | error-census.jsonl MissingXMsVersion ×3 + versioning doc | CLOSED-WITH-RECEIPT (confirmed) |
| KD-138 | real-Azure parity pinion + census witness | error-census.jsonl InvalidQueryParameterValue ×3 + error-codes doc | CLOSED-WITH-RECEIPT (confirmed) |

No fake flips. Register rows carry a re-verification clause citing this receipt.
Falsifier: a live wire probe showing smalt answering 409 on a default-container blob
delete (KD-135), or a 200 on versionless GET / bogus comp= (KD-136/138) would reopen
the respective row.
