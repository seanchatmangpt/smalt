# BK-ERR2 — ERROR_CODES.md projection regen (final)

**Standing: ALIVE** · Context: solo · 2026-10-22 · Lane BK-ERR2, repo /Users/sac/smalt (canonical checkout, MIX_BUILD_ROOT=_build-bkerr2)

## Why

docs/ERROR_CODES.md had pre-existing drift flagged by BK-PROFV, BK-B4R, BK-CONF:
lib drift from the monitor/arm changes left the projection stale. BK-GEN's earlier
regen was restored to HEAD because the tree was moving; the tree has converged.

## What was done

1. **Precondition**: `git status --porcelain` — lib/ (router/ex surfaces driving the
   projection) clean. Only two unrelated test files dirty
   (`test/integration/namespace_put_test.exs`, `test/internal/ets_auto_court_test.exs`).
2. **Regen**: `just gen-error-codes` →
   ```
   python3 scripts/gen_error_codes.py
   wrote /Users/sac/smalt/docs/ERROR_CODES.md (254 rows)
   EXIT=0
   ```
3. **Drift check**: `python3 scripts/gen_error_codes.py --check` →
   `docs/ERROR_CODES.md up to date`, exit **0**.
4. **Test**: `smalt-cli/tests/test_error_codes_doc.py` via `.venv-cli`:
   ```
   3 passed in 0.12s
   ```
   (note: task named `tests/test_error_codes_doc.py`; the file lives at
   `smalt-cli/tests/test_error_codes_doc.py` — no `tests/` dir at repo root.
   `.venv/bin/python` has no pytest; `.venv-cli` is the right interpreter.)

## Diff summary (full diff below)

16 rows changed in 254-row table, **all line-number drift in
`lib/smalt/arm_gateway/router.ex` citations** (uniform +6 shift; e.g. InvalidAction
2314→2320, InvalidBody 7106→7112, TableNotFound 6734→6740). **No new error codes,
no removed codes, no meaning/remediation text changes** — the B4R send-gate/monitor
lib changes shifted line numbers only, they did not add or alter error emissions.

## Embedded diff

```diff
diff --git a/docs/ERROR_CODES.md b/docs/ERROR_CODES.md
index df3922fb..56c76b80 100644
--- a/docs/ERROR_CODES.md
+++ b/docs/ERROR_CODES.md
@@ -26,30 +26,30 @@ post-reset every row cites a literal lib/ source file:line.
 | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
 |---|---|---|---|---|---|
 | arm-gateway | 200 | TagNotFound | lib/smalt/arm_gateway/router.ex:1158 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 400 | InvalidAction | lib/smalt/arm_gateway/router.ex:2314 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 400 | InvalidApiVersionParameter | lib/smalt/arm_gateway/router.ex:1672 | api-version does not match the latest supported version for the target resource type. [annotation] | Send the version from GET /metadata/endpoints / Registry.latest_version/1; the error message names the expected version. |
-| arm-gateway | 400 | InvalidBody | lib/smalt/arm_gateway/router.ex:7106 | Request body is not valid JSON for a JSON-expecting endpoint. [annotation] | Send Content-Type: application/json with a JSON object/array body. |
-| arm-gateway | 400 | InvalidFilter | lib/smalt/arm_gateway/router.ex:2306 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 400 | InvalidRequestBody | lib/smalt/arm_gateway/router.ex:7222 | Blob body could not be read (transport-level read error). [annotation] | Retry the PUT; check client connection stability. |
-| arm-gateway | 400 | InvalidResourceShape | lib/smalt/arm_gateway/router.ex:5584 | GraphLaw ontology admission refused the request: unadmitted resource type or shape-invalid payload. [annotation] | Use a type in Smalt.Registry.admitted_resource_types/0 and a payload satisfying its SHACL shape; refusal is pinned at HTTP 400 (ARM never 422). |
+| arm-gateway | 400 | InvalidAction | lib/smalt/arm_gateway/router.ex:2320 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
+| arm-gateway | 400 | InvalidApiVersionParameter | lib/smalt/arm_gateway/router.ex:1678 | api-version does not match the latest supported version for the target resource type. [annotation] | Send the version from GET /metadata/endpoints / Registry.latest_version/1; the error message names the expected version. |
+| arm-gateway | 400 | InvalidBody | lib/smalt/arm_gateway/router.ex:7112 | Request body is not valid JSON for a JSON-expecting endpoint. [annotation] | Send Content-Type: application/json with a JSON object/array body. |
+| arm-gateway | 400 | InvalidFilter | lib/smalt/arm_gateway/router.ex:2312 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
+| arm-gateway | 400 | InvalidRequestBody | lib/smalt/arm_gateway/router.ex:7228 | Blob body could not be read (transport-level read error). [annotation] | Retry the PUT; check client connection stability. |
+| arm-gateway | 400 | InvalidResourceShape | lib/smalt/arm_gateway/router.ex:5590 | GraphLaw ontology admission refused the request: unadmitted resource type or shape-invalid payload. [annotation] | Use a type in Smalt.Registry.admitted_resource_types/0 and a payload satisfying its SHACL shape; refusal is pinned at HTTP 400 (ARM never 422). |
 | arm-gateway | 400 | LocationMismatch | lib/smalt/arm_gateway/router.ex:833 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
 | arm-gateway | 400 | LocationRequired | lib/smalt/arm_gateway/router.ex:824 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 400 | MissingApiVersionParameter | lib/smalt/arm_gateway/router.ex:3092 | Request omitted the required `api-version` query parameter. [annotation] | Add `?api-version=<era>` matching the era returned by GET /metadata/endpoints or Smalt.Registry.latest_version/1. |
-| arm-gateway | 404 | ActionNotFound | lib/smalt/arm_gateway/router.ex:2978 | POST path is under .../providers/* but is not a known azapi action (lock, setLegalHold). [annotation] | Only .../lock and .../setLegalHold are admitted actions; see Smalt.ArmGateway.Router @actions. |
+| arm-gateway | 400 | MissingApiVersionParameter | lib/smalt/arm_gateway/router.ex:3098 | Request omitted the required `api-version` query parameter. [annotation] | Add `?api-version=<era>` matching the era returned by GET /metadata/endpoints or Smalt.Registry.latest_version/1. |
+| arm-gateway | 404 | ActionNotFound | lib/smalt/arm_gateway/router.ex:2984 | POST path is under .../providers/* but is not a known azapi action (lock, setLegalHold). [annotation] | Only .../lock and .../setLegalHold are admitted actions; see Smalt.ArmGateway.Router @actions. |
 | arm-gateway | 404 | LockNotFound | lib/smalt/arm_gateway/router.ex:1292 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 404 | OperationNotFound | lib/smalt/arm_gateway/router.ex:3849 | Unknown LRO operation id (operations expire with the Store). [annotation] | Re-issue the original PUT to get a fresh Azure-AsyncOperation URL; poll the URL from the response header. |
+| arm-gateway | 404 | OperationNotFound | lib/smalt/arm_gateway/router.ex:3855 | Unknown LRO operation id (operations expire with the Store). [annotation] | Re-issue the original PUT to get a fresh Azure-AsyncOperation URL; poll the URL from the response header. |
 | arm-gateway | 404 | ResourceGroupNotFound | lib/smalt/arm_gateway/router.ex:746 | No resource group with that name exists in the subscription (names are matched case-insensitively). [annotation] | PUT the resource group first (201) or list via GET /subscriptions/{sub}/resourcegroups. |
 | arm-gateway | 404 | ResourceNotFound | lib/smalt/arm_gateway/router.ex:1474 | No resource (or parent of a child resource) with that ID is stored. [annotation] | PUT the resource (or parent) first; check ID casing - storage keys are lowercased IDs. |
-| arm-gateway | 404 | RouteNotFound | lib/smalt/arm_gateway/router.ex:2953 | No route matched the method + path (ARM catch-all or egress catch-all). [annotation] | Check the path against the route list in the cited router; watch trailing slashes and provider prefixes. |
-| arm-gateway | 404 | RuleNotFound | lib/smalt/arm_gateway/router.ex:2331 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 404 | SubscriptionNotFound | lib/smalt/arm_gateway/router.ex:3823 | The subscription id is unknown. [annotation] | List known subscriptions via GET /subscriptions; use one of those ids. |
-| arm-gateway | 404 | TableNotFound | lib/smalt/arm_gateway/router.ex:6734 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
+| arm-gateway | 404 | RouteNotFound | lib/smalt/arm_gateway/router.ex:2959 | No route matched the method + path (ARM catch-all or egress catch-all). [annotation] | Check the path against the route list in the cited router; watch trailing slashes and provider prefixes. |
+| arm-gateway | 404 | RuleNotFound | lib/smalt/arm_gateway/router.ex:2337 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
+| arm-gateway | 404 | SubscriptionNotFound | lib/smalt/arm_gateway/router.ex:3829 | The subscription id is unknown. [annotation] | List known subscriptions via GET /subscriptions; use one of those ids. |
+| arm-gateway | 404 | TableNotFound | lib/smalt/arm_gateway/router.ex:6740 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
 | arm-gateway | 404 | TagNotFound | lib/smalt/arm_gateway/router.ex:1103 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
 | arm-gateway | 404 | TagValueNotFound | lib/smalt/arm_gateway/router.ex:1159 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
 | arm-gateway | 409 | ScopeLocked | lib/smalt/arm_gateway/router.ex:935 | Write/delete refused: a Microsoft.Authorization/locks entry at (or above) the scope is ReadOnly/CanNotDelete (KD-113 leg b). [annotation] | Remove the lock (or use a scope the lock does not cover); real ARM answers 409 ScopeLocked on locked scopes. |
-| arm-gateway | 409 | SecretVersionNotFound | lib/smalt/arm_gateway/router.ex:2728 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
-| arm-gateway | 412 | PreconditionFailed | lib/smalt/arm_gateway/router.ex:3014 | Required If-Match precondition missing (azapi lock action) or etag mismatch (blob writes). [annotation] | Send If-Match with the resource etag (GET first); the lock action requires it. |
-| arm-gateway | 413 | RequestBodyTooLarge | lib/smalt/arm_gateway/router.ex:7213 | Blob exceeds the 8,000,000-byte request body limit. [annotation] | Split or compress the blob; keep PUT bodies under 8 MB. |
+| arm-gateway | 409 | SecretVersionNotFound | lib/smalt/arm_gateway/router.ex:2734 | Error emitted by the substrate; see the cited source for the exact message template. | Read the message body; fix the request per the cited source. |
+| arm-gateway | 412 | PreconditionFailed | lib/smalt/arm_gateway/router.ex:3020 | Required If-Match precondition missing (azapi lock action) or etag mismatch (blob writes). [annotation] | Send If-Match with the resource etag (GET first); the lock action requires it. |
+| arm-gateway | 413 | RequestBodyTooLarge | lib/smalt/arm_gateway/router.ex:7219 | Blob exceeds the 8,000,000-byte request body limit. [annotation] | Split or compress the blob; keep PUT bodies under 8 MB. |
 | arm-gateway | 200 | OperationRecordIncomplete | lib/smalt/arm_gateway/lro.ex:430 | LRO poll returned a terminal Failed record: the stored operation record was missing or had malformed scheduling fields (startedAtMs/delayMs) — only reachable via a direct out-of-mint-path write to the operations store — and was failed instead of wedging in InProgress. Emitted in the 200 poll body's error member, not an error envelope. [annotation] | The operation is terminal; re-issue the original PUT to start a fresh operation and poll its Azure-AsyncOperation URL. |
 | arm-gateway | 400 | PolicyRemediationInvalid | lib/smalt/policy.ex:945 | Policy remediation PUT body invalid (missing policyAssignmentId, or resourceIds not a non-empty list of strings). [annotation] | Send policyAssignmentId plus a non-empty resourceIds list; real ARM refuses malformed remediation bodies with 400. |
 | arm-gateway | 400 | PolicyViolation | lib/smalt/policy.ex:1379 | Azure Policy enforcement denied the write (Smalt.Policy.enforce/4 deny effect). [annotation] | Align the resource with the policy assignment's rules (or update the assignment) before retrying the PUT. |
```

The embedded diff is byte-exact from `git diff docs/ERROR_CODES.md` at regen time
(captured to /tmp/bkerr2-errcodes.diff before staging).

## Falsifier / non-vacuity

If the regen were vacuous, `--check` would exit 1 pre-regen — the pre-existing
lane-flagged failures (BK-PROFV/BK-B4R/BK-CONF) ARE that witness: the check was
failing on HEAD before this lane ran.

## Commands

- `just gen-error-codes` → exit 0, 254 rows
- `python3 scripts/gen_error_codes.py --check` → exit 0
- `.venv-cli/bin/python -m pytest tests/test_error_codes_doc.py -q` (cwd smalt-cli) → 3 passed
