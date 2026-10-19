# kd111-arm-lro-narrow-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-111 (ARM LRO narrow)
- **Standing**: PASS-EVIDENCED (LRO narrowness witnessed on both sides)
- **Context**: solo

## Witness

Substrate: block b3, ARM 39032, auth enforce, Bearer minted (client_credentials).

### Non-LRO type: Microsoft.Network/virtualNetworks → synchronous 201, no async headers

```
$ curl -s -D - -X PUT "$ARM/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Network/virtualNetworks/kdvnet2?api-version=2021-04-01" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"location":"westus","addressPrefixes":["10.1.0.0/16"],"properties":{}}'
HTTP/1.1 201 Created
date: Mon, 19 Oct 2026 17:33:54 GMT (headers: no Azure-AsyncOperation, no Location, no Retry-After)

{"id":".../Microsoft.Network/virtualNetworks/kdvnet2","location":"westus","name":"kdvnet2","properties":{"provisioningState":"Succeeded"},...,"type":"Microsoft.Network/virtualNetworks"}
```

### LRO type: Microsoft.Storage/storageAccounts → 202 + Azure-AsyncOperation + Location + Retry-After

```
$ curl -s -D - -X PUT "$ARM/subscriptions/sub/resourceGroups/kdrg/providers/Microsoft.Storage/storageAccounts/kdsa1?api-version=2021-04-01" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"location":"westus","kind":"StorageV2","sku":{"name":"Standard_LRS"}}'
HTTP/1.1 202 Accepted
azure-asyncoperation: http://127.0.0.1:39032/subscriptions/sub/operations/6b8b10e5354df8d8fbae4e96
location: http://127.0.0.1:39032/subscriptions/sub/operations/6b8b10e5354df8d8fbae4e96
retry-after: 1

{"delayMs":0,"endTime":null,"id":"/subscriptions/sub/operations/6b8b10e5354df8d8fbae4e96","name":"6b8b10e5354df8d8fbae4e96","resourceId":".../storageAccounts/kdsa1","startTime":"2026-10-19T17:34:47Z","startedAtMs":1792431287464,"status":"InProgress"}
```

`lro_type?` in `lib/smalt/arm_gateway/router.ex:2236` covers exactly
`["Microsoft.Storage/storageAccounts", "Microsoft.Compute/virtualMachines"]` — the two
transcripts above are the narrowness evidence: everything else answers synchronously.

## Side finding (first-write 500 crash)

The FIRST vnet PUT on a fresh boot crashed 500:

```
10:33:55.055 [error] arm_gateway crash 500: ** (UndefinedFunctionError) function
Smalt.EgressRouter.Peers.emit_resource_write_success/2 is undefined
(module Smalt.EgressRouter.Peers is not available)
```

An identical retry seconds later answered 201. First-write-only cross-plane emission crash
(`lib/smalt/arm_gateway/router.ex:941`); not repaired (lane scope: evidence only).

## Falsifier status

Skeleton falsifier ("SDK poller completes 202 → terminal on each covered route") was not
run SDK-side; the curl-tier evidence witnesses the divergence shape (202+async headers vs
sync 201) which is what KD-111 registers. Poller-terminal completion remains for a
SDK-probe lane if the registrar wants the full skeleton falsifier.
