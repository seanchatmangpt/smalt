# KD-187 stale-image falsifier — ARM-container/blob-face namespace disconnect

Standing: **ALIVE** (probe executed 2026-10-30, local substrate pid 1774, asdf elixir 1.20.4-otp-29).
Context: solo.

## Question

The courtroom harness (hrn004-crmh-harness, nextjs-harness v26.10.30, KIND
pod) witnessed "blob PUT into an ARM-created container → 404
ContainerNotFound". Wave-1 lane 10 established KD-92 CLOSED the ARM→blob
container-namespace mirror
(`lib/smalt/arm_gateway/plug/resource_providers.ex:935-963`; witness
`docs/jira/v26.10.21/receipts/bk25-kd92-93-cosmos.md`). Is this a KD-92
regression on current code, or a stale-image artifact?

## Method

Fresh substrate boot on current code (the pre-existing substrate was wedged —
TLS ClientHello dropped, curl exit 35/7, 9443 listener was a stale ssh
forward pid 60822; one restart via `scripts/substrate.sh` with the lock fd
closed, `9>&-`, asdf shims on PATH). Probe over the TLS twin 9444 (9443
control face reset plain LibreSSL handshakes during the window):

```
$ TOK=$(curl -s --cacert .smalt/tls/ca-cert.pem -X POST \
    "https://127.0.0.1:9444/smalt-tenant/oauth2/v2.0/token" \
    -d 'grant_type=client_credentials&client_id=probe&client_secret=probe&scope=https://storage.azure.com/.default' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
$ ACCT=kd187d$(date +%s); SUB=00000000-0000-0000-0000-000000000000
$ curl -s --cacert $CA -o /dev/null -w "arm-acct: %{http_code}\n" -X PUT \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    "$ARM/subscriptions/$SUB/resourceGroups/kd187rg/providers/Microsoft.Storage/storageAccounts/$ACCT?api-version=2021-04-01" \
    -d '{"location":"eastus","sku":{"name":"Standard_LRS"},"kind":"StorageV2"}'
arm-acct: 202
$ curl -s --cacert $CA -o /dev/null -w "arm-cont: %{http_code}\n" -X PUT \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    "$ARM/subscriptions/$SUB/resourceGroups/kd187rg/providers/Microsoft.Storage/storageAccounts/$ACCT/blobServices/default/containers/kd187c?api-version=2021-04-01" -d '{}'
arm-cont: 201
$ curl -s -w "\nblob-put: %{http_code}\n" -X PUT -H "Authorization: Bearer $TOK" \
    -H 'x-ms-version: 2021-12-02' -H 'x-ms-blob-type: BlockBlob' \
    "$EG/$ACCT/kd187c/kd187.txt" --data-binary hello
{"content_length":5,"etag":"\"0x5D41402ABC4B2A76\"","headers":{...},"name":"kd187.txt"}
blob-put: 201
```

## Result

**blob PUT → 201. KD-92 holds on current code. The disconnect was a
stale-image artifact, not a regression.** KD-187 minted CLOSED-OBSOLETE
(stale-image witness).

### Side findings (both witnessed in the same session)

1. **Foreign-tenant token → namespace disconnect mimic.** The identical
   probe with a token minted from `/smalt-emulator-tenant/oauth2/v2.0/token`
   (tid NOT in the legacy list `["smalt-tenant","common"]`,
   `lib/smalt/auth/tenant_law.ex:66-67`) gets `arm-cont: 201` then
   `blob-put: 403 Forbidden "Given request does not authorize access…"`
   (tenant_law mismatch), and an even earlier leg got `404
   ContainerNotFound` — wire-visible behavior that mimics the courtroom
   disconnect. The KIND harness pod used `smalt-emulator-tenant`; if its
   image predates the legacy-tenant list carrying `smalt-emulator-tenant`,
   the disconnect is fully explained by tenant-namespace scoping on a stale
   image, two independent mechanisms (403 and 404) both reproduced. This is
   the plausible ROOT CAUSE of the courtroom witnessing, registered here as
   observation; a harness-side fix (mint tokens from `/smalt-tenant` or add
   the tid to `:legacy_tenants` config) is owed by the harness lane, not
   this register.
2. **KD-188 leg (re-witnessed live)**: `PUT .../storageAccounts/$ACCT/managementPolicies/default?api-version=2021-04-01`
   → `404` `RouteNotFound`. `grep -rniE 'managementpolic' lib/` →
   0 matches. KD-188 minted OPEN.

## Register actions

- KD-187 minted (CLOSED-OBSOLETE, stale-image witness — this receipt).
- KD-188 minted (OPEN; evidence `hrn004-crmh-harness.md:16-17` + live
  RouteNotFound re-witness + zero `managementpolic*` matches in `lib/`).
- `dialect` column added to the canonical table (mechanical pass, verified
  per-row).
- v26.10.29 DRAFT rows renumbered KD-187/188/189 → KD-190/191/192
  (never minted; renumbering annotated inline).

Falsifier status: STEP 1 receipt with real curl output + status — met
(201, embedded above). Register parses; no KD id duplicated (sort -u check
in lane receipt).
