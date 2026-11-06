# p3-l1-c1-reanchor

Standing: PARTIAL

Re-anchor receipts for the 19 C1_ARM_REST loci in
`docs/jira/v26.11.7/01-c1-c7-re-anchoring-plan.md` (§ C1_ARM_REST, 19 loci).
Smalt anchors untouched (byte-identical append only). Arcus line numbers
derived at execution time from the landed arcus tree
(`/Users/sac/arcus/internal/dialect/azure/`, read 2026-11-05).

## sha256 of arcus counterparts at pin time

| file | sha256 |
|---|---|
| lro.go | dc3168c66981e95ee4dfaf5a757ec6c4036b59ed64761d0aeb4bba0295d181a1 |
| apiversion.go | 50e5ad0e1042a707a898a79d9369d6155a1b297a5971183c8f8fb2f2f3d12ceb |
| errors_armwire.go | fe4d4a0f9296540a1000ef938b9685fffd1f0b48cdf7fc93547227d122d6682d |
| arm_path.go | 7959da7afce6d3951a32d2b3a37205a504d24e1446bb928e2abe41fe5801cf01 |
| paging.go | 497af29276c1286de08fc859559b4fef56f29bb80bcb5eadc7a430ce38b484e2 |
| gateway.go | feff65bab0bf6180fe0508de36949013f185369a83ed6eb7fb03052894026571 |

## Per-anchor receipts

| locus | smalt anchor (byte-identical) | arcus anchor (pinned) | verification | verdict | Standing |
|---|---|---|---|---|---|
| C1:39 | `router.ex:531-560` send_arm_error/4 | `errors_armwire.go:38-68` | ARMErrorBody/SendARMError render `{"error":{code,message,target?,innererror:{}}}` — same envelope law | PASS | PASS |
| C1:42 | `router.ex:660-671`, `:1075-1084` | `lro.go:190-218` | LroWireBody enriches id/name/type over the op base; provisioningState/systemData legs NOT yet in the dialect (disclosed divergence) | PASS (id/name/type leg) | PARTIAL |
| C1:44 | `router.ex:805-874`, `:618-677` | — | dialect is a law library: no generic sync-PUT 201/200 handler travels (grep for 201/http.Status across dialect: absent) | UNSUPPORTED(counterpart-absent) | PARTIAL |
| C1:45 | `router.ex:860-872` cond, `:2139-2146` headers | `lro.go:27-47,158-169` | lroTypes/LroAsyncUpdateType tables + AsyncPutHeaders (Azure-AsyncOperation + Location + Retry-After) — create/update cond itself not ported | PASS | PASS |
| C1:46 | `router.ex:2139-2146` | `lro.go:163-168` | AsyncPutHeaders sets azure-asyncoperation/location/retry-after:1 | PASS | PASS |
| C1:47 | `router.ex:708` RG delete LRO | `lro.go:176-181` | DeleteHeaders: Location + Retry-After ONLY (non-unification law carried in comment) | PASS | PASS |
| C1:48 | `router.ex:2607` poll; `lro.ex:378-423`; `lro_sweeper.ex:73-88` | `lro.go:108-133,190-218` | Evaluate (pure, due→Succeeded) + LroWireBody terminal poll body; sweeper leg absent (lro.go:113 names it caller-owned) | PASS (evaluate+poll-body legs) | PARTIAL |
| C1:49 | `lro.ex:378-423`, `:70-107`, `:323` | `lro.go:115-133,141-156` | Evaluate/FailClosed ported from evaluate/2, fail_closed/2; get_op/1 reader-routes-persistence leg (`:323`) has no counterpart (writer-owned store absent) | PASS (evaluate/fail-closed legs) | PARTIAL |
| C1:50 | `router.ex:1923-1936`, `:1947-1949` | `apiversion.go:42-57,59-84` | CheckAPIVersion → MissingApiVersionParameter 400; checkVersion monotonic admission | PASS | PASS |
| C1:52 | `router.ex:1985-1991` | `apiversion.go:76-82` | InvalidApiVersionParameter message embeds the latest supported version | PASS | PASS |
| C1:53 | `router.ex:2630-2651` | `arm_path.go:71-73` | ParseArmPath accepts both `resourceGroups` and `resourcegroups`; entitypath.go (plan-named) carries messaging-entity grammar, not the ARM segment law — arm_path.go is the real counterpart | PASS | PASS |
| C1:54 | `router.ex:2124-2128` | — | no provider-namespace downcase anywhere in the dialect (ToLower hits are acr/apim/blob faces, not ARM provider admission); ParseArmPath matches seg[5] exactly | UNSUPPORTED(counterpart-absent) | PARTIAL |
| C1:55 | `router.ex:433-452`, `:609-616`, `:411` | `paging.go:17-42` | Page envelope `{"value":[...], nextLink}` + NextLink absolute-URL rebuild with api-version forward-carry, maxitempages clamp, $skip | PASS | PASS |
| C1:58 | `router.ex:53,101`, `:53-54` | `gateway.go:76-99` | RequestID middleware echoes/mints RFC4122 v4, stamped on every response incl. errors | PASS | PASS |
| C1:59 | `router.ex:54,132` | `gateway.go:120-135` | Throttle hook renders ARM 429 envelope + Retry-After; nil hook = DEFAULT-OFF parity | PASS | PASS |
| C1:60 | `router.ex:186` | `gateway.go:183`, `errors_armwire.go:64` | Content-Type `application/json; charset=utf-8` set on both emit paths | PASS | PASS |
| C1:90 | `lro.ex:378-423`, `lro_sweeper.ex:73-88` | `lro.go:141-156` | FailClosed mints OperationRecordIncomplete Failed terminal | PASS | PASS |
| C1:135 | `lro.ex:378-423` | `lro.go:108-133,141-156` | doc prose restates the one-writer flip law; Evaluate/FailClosed with caller-owned-writer comment at lro.go:108-114 | PASS | PASS |
| C1:139 | `lro_sweeper.ex:73-88` | — | no Sweeper GenServer/law in the dialect; lro.go:113 comment explicitly defers the terminal writer to the caller | UNSUPPORTED(counterpart-absent) | PARTIAL |

## Summary

- 19/19 loci anchored (`grep -c '<- arcus:' C1_ARM_REST.md` = 19, re-read
  at receipt-write time).
- Verdicts: 16 PASS, 3 UNSUPPORTED(counterpart-absent) — C1:44 (sync-PUT
  handler), C1:54 (provider downcase), C1:139 (sweeper). Zero
  silently-missing cells.
- Doc-level completion receipt (`p3-reanchor-summary.md`) is NOT this lane's
  file; C2-C7 receipt files are separate lanes' outputs.
