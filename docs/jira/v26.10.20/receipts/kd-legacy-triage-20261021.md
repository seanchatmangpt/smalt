# KD legacy pre-window triage — live-substrate probes (kd-registrar, 2026-10-21)

Substrate: shared substrate pid 6909 (UP during probes; control plane 9443 is
PLAIN HTTP, TLS twin 9444, data plane 8443 plain HTTP, AMQP 5672).
Auth: bearer minted from the emulator STS
`POST https://127.0.0.1:9444/smalt-emulator-tenant/oauth2/v2.0/token` (200).

## Probe transcript (exit codes and bodies verbatim)

    # KD-04
    curl -s -H "Authorization: Bearer $TOK" -H "x-ms-version: 2021-12-02" \
      'http://127.0.0.1:8443/smalt/kd04c?restype=container&comp=bogus'
    -> 400, body Code=InvalidQueryParameterValue
       ("The comp value 'bogus' is not supported (GAP(blob-comp-lease-absent))...")

    # KD-13 (full soft-delete lifecycle, all 200)
    create  POST /keys/kd13full/create           -> 200
    delete  DELETE /keys/kd13full                -> 200 (soft-delete envelope, deletedDate set)
    getDeleted GET /deletedkeys/kd13full         -> 200
    recover POST /deletedkeys/kd13full/recover   -> 200
    get     GET /keys/kd13full                   -> 200

    # KD-10 / KD-75 (updateKey face = PUT /keys/:name)
    curl -X PUT .../keys/kd10probe?api-version=7.4  -> 404
      {"error":{"code":"NotFound","message":"PUT /keys/kd10probe is not
       implemented on this plane (reserved namespace 'keys'); nothing was stored."}}

    # KD-14 (RS256 sign/verify, key kd14probe, kid .../keys/kd14probe/645)
    POST /keys/kd14probe/sign   {alg:RS256,value:<sha256hex>}      -> 200
    POST /keys/kd14probe/verify {alg,digest,value}                 -> 200 {"valid":false}
    external cryptography.hazmat verify over the digest:  FALSE
    external cryptography.hazmat verify over the raw message: FALSE
    (both external legs false = the substrate signature is still non-standard)

    # KD-23 (ResourceGraph, api-version 2022-10-01, POST /providers/Microsoft.ResourceGraph/resources)
    "| project name"                                        -> 200 (5 records)
    'where type =~ "..." | project id, name'  (bare-mixed)  -> 500 InternalServerError
    '| where type =~ "..." | project id, name' (pipe-mixed) -> 500 InternalServerError
    (BOTH mixed forms now 500 crash-class; the original 400 BadQuery became a 500)

    # KD-79 (ARM vault PUT 202 -> GET 200, api-version 2023-02-01)
    vaultUri = http://127.0.0.1:9443/   (loopback echo — design constant holds)

    # KD-92 (ARM child container PUT -> data-plane blob PUT)
    ARM PUT .../storageAccounts/smalt/blobServices/default/containers/kd92c -> 201
    data-plane PUT /smalt/kd92c/kd92.txt  -> 404 ContainerNotFound  (DIVERGENCE LIVE)
    GET  -> 404 BlobNotFound

    # KD-93 (cosmos fresh run-unique db kd93fresh1792603476)
    db 201, coll 201, doc PUT 201, direct GET 200, query feed (parameterized
    filter, fresh db) -> 201 with Docs ids: []   (DIVERGENCE LIVE: fresh db
    query feed returns EMPTY — no stale ids served, but read-your-write still fails)

    # KD-86 (rhea sender open to a never-created queue name on 5672)
    sender link DETACHED by the broker (condition undefined) under enforce auth
    without a CBS token — inconclusive on auto-ensure (auth confound);
    code-layer face unchanged: queue_store.ex:210/356/380 put/dlq paths still
    call ensure_queue/1 — auto-creation is still on the send path.

    # KD-90 (bench receipt re-read)
    docs/jira/v26.10.16/bench/affidavit-seal.jsonl lane c10 run: op
    admit_and_seal, n=100, errors 0, p50 11.265ms / p95 26.491ms / max 35.248ms,
    engine_sha256 9b2908e4...  (still b3sum-subprocess-floor; no in-process NIF swap)

**Standing:** PASS (probes executed on the live substrate; KD-86 leg inconclusive)
