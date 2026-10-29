# BK-149 — smalt-cli inventory-and-close receipt

**Standing: PARTIAL_ALIVE** — all 5 Typer command groups (storage / cosmosdb /
servicebus / keyvault / deployment) pass on real wire against a live substrate
(11/11 in-sequence, all green in the full `tests/` suite); 3 residual failures
in the full suite are typed out-of-lane (see Gap list). `Context: solo`

## Subject

- Repo: /Users/sac/smalt @ main (coordinator tick checkpoints adc32ec2/7e0cb006
  snapshotted in-flight BK-149 edits; remaining uncommitted diff owned by this
  lane, per lane law — no commits by this lane)
- Scope: `smalt-cli/` (cli.py master app, commands/ 5 groups, wire.py, tests/)

## Environment gate (session finding)

The substrate lane boots fail-closed on toolchain: `mix.exs` declares
`~> 1.20`; PATH Elixir was 1.19.5 → `SUBSTRATE_DIED rc=1` for every
substrate-backed test (loud skip, never a fake pass — correct behavior).
Closed by pinning the test toolchain: `PATH=$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH`.

## Per-group test outputs (real wire, live substrate)

| group | file | result |
|---|---|---|
| storage | tests/test_ty_storage.py | 3 passed (container create+list, blob upload+ETag, missing-container ANDON) |
| cosmosdb | tests/test_ty_cosmosdb.py | 1 passed (db/container create, doc put/get, If-Match ETag-CAS: current-ok + stale-412-ANDON, delete, 404 ANDON) |
| servicebus | tests/test_ty_servicebus.py | 1 passed (ARM queue-create w/ sku → AMQP send + receive roundtrip) |
| keyvault | tests/test_ty_keyvault.py | 5 passed (secret set/get; RSA/EC/oct-HSM key create; release-policy; PS256 sign+verify; **certificate-create/get — new this lane**) |
| deployment | tests/test_ty_deployment.py | 2 passed (group-create → deployment create materializes SB ns+queue → AMQP send proves resource REAL; show=Succeeded; bad-template ANDON) |

Full suite: `python3 -m pytest tests/ -q` → **3 failed, 116 passed, 11 skipped**
(71s). Skips are the conftest's typed loud skips (KD banners / premise-rot
banners), never silent.

## Defects found and closed (all in smalt-cli/, this lane)

1. **cosmosdb doc CRUD refused 400 on partitioned containers** — substrate
   enforces `x-ms-documentdb-partitionkey`; CLI sent none. Fix:
   `commands/cosmosdb.py` `_pk_header()` GETs the container, derives the pk
   value from `partitionKey.paths` + the doc (bool→"true"/"false", else str(),
   mirroring server-side PartitionKey.extract).
2. **wire.cosmos_request dropped extra_headers on the tokenless first
   request** — the pk header only rode the 401-retry. Fix: headers ride every
   request; bearer is added on 401 retry (KD-15 handshake preserved).
3. **servicebus queue-create 400**: substrate GraphLaw requires sku on
   ServiceBus namespaces → now sends `sku:{name,tier}=Standard`; **202
   accepted** (ARM async provisioning semantics, real-Azure parity).
4. **servicebus SAS key**: CLI default key was a string the substrate's CBS
   SAS verifier refuses (`amqp:client-error` auth fail). Fix: default key is
   now the deterministic dev-key derivation
   `base64(sha256(hostname <> "smalt-dev-sb"))` (SasVerifier law,
   scripts/dev_env.sh parity); `SMALT_SB_SHARED_KEY` still overrides. Typer
   enforce-lane tests pass the lane key (`conftest._ENFORCE_SB_KEY`).
5. **servicebus receive body decoding**: `str(m.body)` produced a generator
   repr / `.decode` on str / bytes-join TypeError. Fix: `_body_text()` handles
   generator | list | bytes | str (AmqpAnnotatedMessage bodies included).
6. **deployment create silently admitted a non-list `resources`** (empty
   applied list, exit 0 = fake pass). Fix: typed ANDON; also unwraps the
   `{"properties":{"template":{...}}}` shape so a wrapped file is not read as
   an empty template; resource PUTs now carry the full resource body
   (location/sku — without type/name/apiVersion) and accept 202.
7. **enforce-lane Typer tests bound `conftest.ARM` at import time** — module
   import read the pre-fixture default (39643) while the enforce fixture
   rebinds to 38654 → ConnectError. Fix: all five ty files read `conftest`
   lazily; anonymous-lane files pin `conftest.ANON_ARM/ANON_EGRESS` (new
   constants) because the enforce fixture's session-scoped rebinding persists
   past enforce modules (witnessed: ty_storage 401 against the enforce egress
   when run after it alphabetically).
8. **test_w3_session_ops premise rot**: (a) namespace/RG/queue PUT asserts
   accepted only (200,201) — substrate now answers 202 (async); (b)
   `w3-batchdel-q`/`w3-batchdel2-q` were never provisioned →
   `amqp:unknown-error` on send (entity absent). Fix: accept 202; provision
   both queues via the admitted ARM child-PUT surface. Lane: 3 passed,
   1 skipped (typed KD77-residual banner).
9. **keyvault certificate gap closed**: new `certificate-create` /
   `certificate-get` commands (POST /certificates/:name/create,
   GET /certificates/:name — substrate KvRoutes KD-104 face) + roundtrip test.

## wire.py transport + endpoint/auth law (verified)

- Import: OK (XMS blob version 2021-04-01 pinned, KV api-version 7.4).
- Loopback law: non-loopback SMALT_ARM / SMALT_EGRESS / **SMALT_AMQP** (new —
  was unchecked) refused with `NON_LOOPBACK_ENDPOINT`; probe run confirms
  refusal for `http://10.0.0.5:9443`, `https://example.com`, `10.1.2.3:5672`.
- Auth law: STS client_credentials over ARM (works anonymous + enforce), KD-15
  tokenless-401-then-bearer challenge on KV/cosmos faces.

## Remaining gaps (typed, out of this lane's ownership)

| gap | type | owner/evidence |
|---|---|---|
| `test_error_codes_doc` fails: docs/ERROR_CODES.md stale vs `scripts/gen_error_codes.py` projection | pre-existing repo-wide projection drift | regenerated by `just gen-error-codes` — repo-level artifact other lanes are actively editing; regenerating under them risks collision |
| `test_blob.py::test_immutable_overwrite_409_container_locked` fails (raw SDK lane, no smalt-cli code) | pre-existing substrate/lib blob-WORM face vs test premise | out of lane (lib/ surface) |
| `test_cosmos.py::test_whitelist_refuses_grammar_external_queries_400[OFFSET 1 LIMIT 1]` fails (substrate accepts the query, test expects typed 400) | pre-existing substrate CosmosSql grammar drift | out of lane (lib/smalt/cosmos_sql.ex surface) |
| `az bicep build` untestable here: az CLI absent on this host | typed | deployment create ANDONs honestly ("requires the az CLI (not on PATH)") rather than faking — the refusal path is the verified behavior |
| SB batch-send (pyamqp BatchMessage list-send) → `amqp:unknown-error` to unprovisioned entities | typed | raw-SDK probe witnessed; with provisioning (fix 8) the w3 lane passes; a KD row candidate for the missing-entity error condition (would be minted by the kd-registrar, not this lane) |

## Commands / exits

- Per-group runs (exit 0 each): see table above.
- Full suite: `python3 -m pytest tests/ -q` → 3 failed / 116 passed / 11
  skipped, exit 1 (the 3 typed pre-existing out-of-lane failures).
- Law probe: inline python (exit 0) — loopback refusals verified.

## Environment note for the next runner

Substrate-backed tests need `PATH=$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH`
(mix.exs `~> 1.20`) and `azure-*` SDKs (azure-servicebus, azure-storage-blob,
azure-cosmos, azure-eventhub, azure-identity, azure-mgmt-resourcegraph,
azure-keyvault-*, pyserial) — all installed this session
(`pip install --break-system-packages`).
