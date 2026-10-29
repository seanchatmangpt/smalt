# KD-102 close witness — KV secrets soft-delete plane (lane K7, 2026-10-21)

**Standing:** PASS
Context: solo

Surface already landed (KvRoutes.ex `# KD-102` deleted-secrets plane + keys twin;
`/deletedsecrets` registered in application.ex TlsTwinDispatch). This lane verified
the falsifier end-to-end over the live TLS twin (9444, bearer from emulator STS):

    put:200            PUT /secrets/k7sd {"value":"sd"}
    del:200            DELETE /secrets/k7sd
    getdel:            recoveryId=https://smalt-vault/deletedsecrets/k7sd
    recover:200        POST /deletedsecrets/k7sd/recover
    get:sd             GET /secrets/k7sd → value restored
    listdel:200        GET /deletedsecrets
    del2:200           DELETE again
    purge:204          POST /deletedsecrets/k7sd/purge
    get404:404         GET /secrets/k7sd → typed SecretNotFound after purge

Full roundtrip (put → delete → getDeletedSecret w/ recoveryId → recover → get →
list → purge → typed 404) passes on the real wire. KD-102 is FLIP-ELIGIBLE
(keep-condition: row flip runs through scripts/kd_flip.py, receipt-gated).