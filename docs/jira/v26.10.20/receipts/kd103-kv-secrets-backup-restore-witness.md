# KD-103 close witness — KV secrets backup/restore wire arm (lane K7, 2026-10-21)

**Standing:** PASS
Context: solo

Engine (`VaultData.backup_secret/restore_secret`) landed in wave-6 but the wire
arm for the real Azure restore shape — `POST /secrets/restore` (body {"value":
blob}) — was missing: a bare /secrets/restore fell through to the blob catch-all
with a typed MissingXMsVersion refusal (witnessed pre-fix). Lane K7 added the
fixed-segment routes `post "/secrets/restore"` and `post "/keys/restore"` in
lib/smalt/egress/KvRoutes.ex, marked `# KD-COVERS: KD-103`, with the engine's
`{:error, "Conflict", msg}` refusal mapped to Azure 409 (witnessed 400 pre-fix,
409 post-fix).

Live wire over the TLS twin (9444, bearer from emulator STS), final run:

    put:200        PUT /secrets/k7f {"value":"final"}
    backup:200     POST /secrets/k7f/backup → SMALT-KVB1 blob (368 chars)
    del:200        DELETE /secrets/k7f
    purge:204      POST /deletedsecrets/k7f/purge
    restore:201    POST /secrets/restore {"value": blob}
    get:           GET /secrets/k7f → value "final" restored
    conflict:409   second restore of a live secret
    tamper:400     {"code":"MalformedBackupBlob","message":"backup blob is not base64-encoded JSON"}

Falsifier (backup → delete → purge → restore → get roundtrip succeeds) passes.
KD-103 is FLIP-ELIGIBLE.

Compile-freeze disclosure: during this lane's edits a concurrent lane truncated
lib/smalt/egress/KvRoutes.ex to a 416-byte fragment (19:14, /tmp/kvroutes_base.ex
snapshot also 0 bytes). K7 restored the shared file from lane k3's byte-complete
19:08 snapshot (/private/tmp/k3_KvRoutes.ex.orig, contains the KD-102 deleted-secrets
plane + KD-103 routes) and re-applied the K7 409 Conflict mapping on top; `mix compile`
green after restore. Restore is disclosed here per the same-checkout fan-out rules.