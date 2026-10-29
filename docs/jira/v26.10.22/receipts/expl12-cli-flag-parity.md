# EXPL-12: smalt-cli flag-level parity vs real az CLI

Standing: PARTIAL_ALIVE · Context: solo · 2026-10-22 · Lane EXPL-12 (read-only explore; only this receipt written)

Scope: the 5 command groups in `smalt-cli/smalt_cli/commands/` (storage, cosmosdb,
servicebus, keyvault, deployment). There is **no login or monitor group** — `az
login`/monitor surface is absent (auth rides the emulator STS internally); named
honest gap, not audited further. BK-149/149b/149C proved transport-level typing;
this receipt covers FLAG-level parity (names, defaults, required-vs-optional,
value formats) against real az CLI conventions (az ~2.6x, as of 2026).

Env used for witnesses: substrate UP (pid 76687) but booted **plain HTTP** on
9443/8443 (TLS twin on 9444) — CLI defaults (`https://127.0.0.1:9443|8443`)
fail with `ConnectError: Connection reset`; witnesses required
`SMALT_ARM=http://127.0.0.1:9443 SMALT_EGRESS=http://127.0.0.1:8443`
(see P3 finding).

## Per-command flag tables (smalt vs real az)

### storage (blob)

| smalt command | smalt flags | real az counterpart | divergences |
|---|---|---|---|
| `storage container-create` | POS name; `--immutable/--no-immutable` (default immutable); `-o` | `az storage container create --name -n --account-name [--public-access --metadata --fail-on-exist --default-encryption-scope --auth-mode]` | (1) POS name vs `-n`; (2) `--immutable` is EXTRA (az: immutability is a separate `az storage container immutability-policy create --period` flow); (3) **silent no-op on this substrate — witness W1**; missing `--metadata`, `--public-access`, `--account-name`/auth trio |
| `storage container-list` | `-o` | `az storage container list --account-name ...` | implicit fixed account `smaltacct`; missing `--account-name`, `--prefix`, `--num-results`, `--include` |
| `storage blob-upload` | POS container, blob, data; `-o` | `az storage blob upload -c -n -f/--data --overwrite --content-type --metadata --tier` | POS-only; missing `--overwrite` guard (az refuses overwrite without it), `--content-type`, `--metadata`, `--tier`; `--data` (string payload) does exist in modern az — format OK |

### cosmosdb

| smalt command | smalt flags | real az counterpart | divergences |
|---|---|---|---|
| `cosmosdb database-create` | POS name; `-o` | `az cosmosdb sql database create --account-name --resource-group -n` | missing `--account-name`/`-g` context (emulator is single-account — named scope divergence) |
| `cosmosdb container-create` | POS database, container; `--partition-key /pk` (default `/pk`); `-o` | `az cosmosdb sql container create --partition-key-path` | flag NAME mismatch (`--partition-key` vs az `--partition-key-path`); missing `--throughput/--max-throughput`, `--idx`, `--ttl`. Flag mechanism itself is CLEAN — witness W2 |
| `doc-put` | POS db, coll, id, body | — (az CLI has no document data-plane commands) | extra surface (emulator extension, honest); `_pk_header` derivation CLEAN (witness W2 leg 3) |
| `doc-get`/`doc-replace`/`doc-delete` | POS; `--if-match` on replace | — | `--if-match` matches the real Cosmos If-Match ETag-CAS convention (clean) |

### servicebus

| smalt command | smalt flags | real az counterpart | divergences |
|---|---|---|---|
| `servicebus queue-create` | POS queue; `--namespace -n`; `-g`; `--subscription -s`; `-o` | `az servicebus queue create -g --namespace-name --name` | **short-flag collision: `-n` = `--namespace` here but az `-n` = `--name` (the queue name)** (P1); missing all ~20 entity props az has (`--max-size --lock-duration --default-message-time-to-live --enable-dead-lettering-on-message-expiration ...`), body PUTs `{}` |
| `send` | POS queue, message | — (az CLI has no SB data-plane commands) | extra surface, honest |
| `receive` | `--max -m`, `--wait -w` | — | extra surface, honest |
| `peek-dead-letter` | `--max -m` | — | extra surface, honest |

### keyvault

| smalt command | smalt flags | real az counterpart | divergences |
|---|---|---|---|
| `secret-set` | POS name, value | `az keyvault secret set --vault-name -n --value [--expires --tags --encoding --file]` | missing `--vault-name` (implicit single vault), `--expires/--tags/--file/--encoding` |
| `key-create` | POS name; `--kty` (default RSA — matches az default); `--release-policy` (INLINE JSON) | `az keyvault key create --kty --key-size --protection --curve --ops --release-policy <file>` | `--release-policy` FORMAT mismatch: az takes a JSON **file path**, smalt inline JSON (P2); missing `--key-size/--protection/--curve/--ops` |
| `sign` | POS name, data; `--alg` (PS256 default), `--verify/--no-verify` | — (az CLI has no KV crypto data-plane commands) | extra surface, honest; PS256 + pre-hashed b64url digest matches KV REST spec |
| `certificate-create` | `--subject` | `az keyvault certificate create --vault-name -n --policy <file>` (policy REQUIRED) | format/shape mismatch: az requires a policy FILE, smalt a `--subject` shortcut |

### deployment

| smalt command | smalt flags | real az counterpart | divergences |
|---|---|---|---|
| `deployment group-create` | POS name; `--location -l` (default eastus — matches az default region convention); `-s` | `az group create -n -l` | POS name vs `-n`; missing `--tags` |
| `deployment create` | POS name; `-g`; `-s`; `-t/--template`; `--bicep`; `--mode` (Incremental — matches az); `-o` | `az deployment group create -n -g -f/--template-file [-p/--parameters] -m/--mode` | **missing `-p/--parameters`** (smalt always PUTs `"parameters": {}`) (P1); `-t/--template` vs az `-f/--template-file` name mismatch; `--bicep` is extra (az is a separate `az bicep build` command) |
| `deployment show` | POS name; `-g`; `-s` | `az deployment group show -n -g` | POS name |

## Witnesses (real substrate, real wire)

Substrate UP (pid 76687), HTTP planes; `SMALT_ARM=http://127.0.0.1:9443`,
`SMALT_EGRESS=http://127.0.0.1:8443`, dev key from `scripts/dev_env.sh`.

### W1 — storage `--immutable/--no-immutable` is a silent no-op (P0)

Via the CLI's own `smalt_cli.wire` (its STS token, its header builder):

```
sts token acquired: True
A create immutable(default): 201
A upload: 201
A overwrite on immutable (expect 409 WORM refuse): 201   <-- refused-never
B create with --no-immutable header: 201
B overwrite on mutable (expect 201): 201
```

Cause chain, read from source: `storage.py container_put_headers` sends
**no** header on the `--immutable` default; egress_router.ex:1418 (KD-135,
Azure-parity) treats absent `x-ms-immutable-policy` as immutable=**false**
("a container is writable unless explicitly created immutable"). So BOTH flag
directions create a writable container. The flag never flips the wire. The
substrate's WORM machinery itself is fine (a container created WITH
`x-ms-immutable-policy: true` blocks overwrites — gates/ has a blob-worm
invariant gate); the CLI flag fails to invoke it.

Repair: default leg must send `x-ms-immutable-policy: true`; re-point the help
text (it currently claims "WORM/immutable container (substrate default)" —
stale premise pinned to a pre-KD-135 substrate). Also note the KD-135 flip
contradicts the CLI docstring "substrate default" — the substrate's default is
now Azure parity (writable), the CLI's help is the stale side.

### W2 — cosmos `--partition-key` DOES land on the wire (flag mechanism clean)

```
database-create expl12db      -> 201
container-create --partition-key "/tenant" -> 201
GET colls: 200 paths: ["/tenant"]                       <-- flag on the wire
doc-put WITHOUT pk field: 400                            <-- server enforces pk
doc-put WITH pk field (full CLI): 409 (already exists from 201 direct PUT)
doc-get d2 -> full doc, _etag present
```

Flag name diverges from az (`--partition-key-path`), but the mechanism is
correct end-to-end: paths persist, server refuses pk-less docs with 400, the
CLI's `_pk_header` derivation + `doc-put`/`doc-get` round-trip clean. Clean
bill for the flag mechanism; name repair is cosmetic.

### W1b (incidental) — storage group lacks the KD-15 challenge handshake

First run of `storage container-create` against the substrate 401'd with a
bare `ANDON ... (HTTP 401)` and NO bearer retry — `storage.py` PUTs tokenless
and never retries, while `wire.kv_request`/`cosmos_request` both implement the
KD-15 tokenless→401→bearer handshake (corpus premise pin). The storage group
is the only one missing it. Witnessed, exit 1 ANDON.

## Ranked findings + repair tickets

- **P0 EXPL12-1** — `storage container-create --immutable/--no-immutable`
  silent no-op (W1). Repair: send `x-ms-immutable-policy: true` on the
  default leg; fix help text; add a court leg asserting default-created
  containers refuse blob overwrite with 409.
- **P1 EXPL12-2** — storage group missing KD-15 challenge handshake (W1b):
  every storage command 401s ANDON against an `:enforce` substrate where
  cosmos/kv succeed. Repair: route storage through a `blob_request` helper
  with the same handshake as `kv_request`.
- **P1 EXPL12-3** — servicebus `-n` short flag = `--namespace`, colliding
  with az's `-n` = `--name` muscle memory; plus POS queue name. Repair: make
  `--namespace-name` the long form (az parity) and keep `-n` ONLY if the long
  form is `--name`; or drop `-n` from namespace.
- **P1 EXPL12-4** — `deployment create` missing `-p/--parameters`; always
  PUTs `parameters: {}`. Templates with parameterized resources silently get
  defaults. Repair: add `--parameters` (repeatable `key=value` or JSON), pass
  through to the deployment body.
- **P2 EXPL12-5** — flag-name drift: cosmos `--partition-key` vs az
  `--partition-key-path`; deployment `-t/--template` vs az `-f/--template-file`;
  servicebus `--namespace` vs az `--namespace-name`. Repair: accept both
  spellings (az name primary).
- **P2 EXPL12-6** — keyvault `--release-policy` inline JSON vs az FILE path;
  `certificate-create --subject` vs az required `--policy` file. Repair:
  accept `@file` syntax or a file path; keep inline as fallback.
- **P2 EXPL12-7** — missing flags: storage `--metadata/--public-access/
  --overwrite`, keyvault `--expires/--tags/--key-size/--protection`, group
  `--tags`, servicebus entity props. Repair: additive flags with az names.
- **P3 EXPL12-8** — substrate booted plain HTTP on 9443/8443 this session;
  CLI defaults to https and dies with raw `ConnectError` (uncaught traceback,
  not an ANDON). Repair: catch ConnectError → typed ANDON; and make scheme
  discovery honor a `SMALT_*_SCHEME` or default http when TLS twin absent.
- **P3 EXPL12-9** — no `login`/`monitor` groups exist; auth is implicit STS.
  Named gap (honest; emulator scope).

## Clean bills

- cosmos `--partition-key` mechanism end-to-end (W2); `_pk_header` pk
  derivation; `doc-replace --if-match` ETag-CAS convention.
- servicebus `--subscription` path semantics (rides the ARM path like real az).
- keyvault `--kty` default RSA (matches az default); `sign --alg PS256` +
  pre-hashed b64url digest (KV REST spec); `--verify` leg POSTs the real
  /verify endpoint.
- deployment `--mode` default Incremental (matches az); bicep via real
  `az bicep build` subprocess with honest ANDON when az absent.
- blob-upload `x-ms-blob-type: BlockBlob` + `x-ms-version 2021-04-01` headers;
  container-list `comp=list` XML face.
- ANDON refusal discipline: every non-2xx refuses loudly with exit 1 (W1b's
  401 was a loud refusal, not a fake pass).

## Residue

Scratch resources left in the emulator store: containers `expl12-imm`,
`expl12-mut`, `expl12-witness-imm` (create 401'd, may not exist), database
`expl12db` (container `expl12pk`, docs d1/d2). Emulator-local, namespaced by
the expl12 prefix.
