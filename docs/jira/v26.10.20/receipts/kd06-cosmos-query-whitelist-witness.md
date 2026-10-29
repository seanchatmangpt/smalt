# KD-06 witness — cosmos query whitelist (K2 lane, 2026-10-21)

**Standing:** ALIVE (closed as typed-UNSUPPORTED closure via the Smalt.CosmosSql translator)

Close condition: "pin alias set in whitelist (admit or type UNSUPPORTED)". The
whitelist fast path stays for `SELECT * FROM <alias>`; every other query is
parsed by `Smalt.CosmosSql` and evaluated over the scoped set; anything outside
the grammar is a typed 400 (SyntaxError / InvalidQuery) — never a silent wrong
answer. `KD-COVERS: KD-06` token at `lib/smalt/data_plane/cosmos.ex` (whitelist
gate).

## Live wire proof (substrate on 8443, bearer from 9443 STS)

```
$ curl -X POST .../dbs/k2db*/colls/k2c/docs -H 'Content-Type: application/query+json' -d '{"query":"SELECT * FROM root"}'
{"Documents":[...],"_count":1,"_rid":"w3qz8XzyXOr-"} [200]          # non-c alias admitted

$ ... '{"query":"SELECT * FROM c WHERE c.v=3"}'
{"Documents":[{u1 v=3}],"_count":1} [200]                            # read-your-write filter evaluated

$ ... '{"query":"SELECT VALUE c.id FROM c"}'
{"code":"SyntaxError","message":"Expected FROM <alias>"} [400]       # typed refusal outside grammar

$ ... '{"query":"SELECT * FROM c WHERE true"}'
{"code":"SyntaxError","message":"Expected comparison operator"} [400]
```

`SELECT * FROM root` is admitted (the row's divergence). Non-`SELECT * FROM c`
forms are either evaluated (WHERE forms) or typed 400 — the "other forms 400
wholesale" lie is narrowed to typed fail-closed refusals. KD-93 (scope/
freshness) remains a separate OPEN row, not touched here.

Verification: live-substrate curl against 127.0.0.1:8443, real STS bearer,
fresh run-unique db (`k2db$(date +%s)`); `# KD-COVERS: KD-06` in lib/;
kd_flip dry-run FLIP-ELIGIBLE (see kd-registrar handoff).

## Verdict

PASS — live wire: non-c alias admitted (200), WHERE forms evaluated, outside-grammar forms typed 400.
