# Provider Court Receipt — 2026-10-30 (lane F2)

## Subject

- Repo: `/tmp/f2-provider/terraform-provider-smalt` (Elixir provider spike, extracted from
  `~/smalt/tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`; the in-tree
  copy at `~/smalt/terraform-provider-smalt` is ERRC-deleted per POSH-007 — not resurrected).
- Substrate: smalt-on-kind ARM face `http://127.0.0.1:9443` (`/metadata/endpoints` 200;
  `/healthz` bearer-gated 401 unauth / 200 with STS-minted bearer).
- Court: `scripts/provider_court.sh` — 8 stages, fail-closed.
- Final standing: **ALIVE — court exit 0**, twice consecutively on clean state.

## Verbatim stage lines (final run, 2026-10-30T20:29:20Z)

```
[stage1] PASS (substrate /metadata/endpoints 200 at http://127.0.0.1:9443/metadata/endpoints)
[stage2] PASS (3.6K binary present)
[stage3] PASS (fmt clean, init -backend=false ok, validate ok under rc .../bin/provider-smalt.tfrc)
[stage4] PASS (plan exit 2; Plan: 3 to add, 0 to change, 0 to destroy.)
[stage5] PASS (Apply complete! Resources: 3 added, 0 changed, 0 destroyed.)
[stage6] PASS (RG present in ARM state pre-destroy; destroy complete; court-owned residue 0)
[stage7] PASS (re-apply + re-plan -detailed-exitcode 0, No changes)
[stage8] PASS (receipt ...)
COURT-EXIT=0
```

Both GREEN runs: 20:29:20Z and the confirming run immediately after (same 8/8 PASS, exit 0).

## Verification ladder

- `mix test` — 5 tests, 0 failures (after each lib fix; all green at final build).
- `mix compile` — clean (pre-existing warnings in core/plan.ex unchanged).
- Stage 3: `terraform fmt -check`, `init -backend=false`, `validate` under the rc.
- Stage 4-5: real plan + apply against the live substrate (rg + capp env + kv).
- Stage 6 falsifier 1: STS token POST `/smalt/oauth2/v2.0/token` (client_credentials) →
  bearer-authenticated ARM GETs prove applied resources in SMALT state (not tfstate);
  destroy → court-owned residue 0 (scoped to court-owned RG names; the subscription is
  shared with concurrent irtc-* lanes).
- Stage 7 zero-drift: re-apply → `plan -detailed-exitcode 0` = "No changes" → final destroy.

## Harness/orchestration work (session-introduced, per lane contract)

- `scripts/build_install.sh`, `scripts/tfrc.sh` — written fresh (missing from archive).
  Attribute-form `dev_overrides { "hashicorp/azurerm" = "<bin dir>" }` (TF 1.14 rejects
  labeled blocks); never touches `~/.terraformrc`.
- `bin/terraform-provider-azurerm` — go-plugin AutoMTLS wrapper: TF 1.14 sends
  `PLUGIN_CLIENT_CERT` and dials TLS+ALPN h2 unconditionally; the spike serves plaintext
  gRPC. Wrapper spawns the escript, TLS-terminates via `tools/tls_proxy.py` (stdlib-ssl,
  ALPN h2, client-cert verify against `PLUGIN_CLIENT_CERT`, fresh cert with
  `IP:127.0.0.1,DNS:localhost` SANs, DER b64 RawStd in handshake field 6) and forwards
  plaintext. No lib/ change; the ladder is exercised over real mTLS.
- `examples/kind/main.tf` — trimmed to the substrate-supported face
  (rg + container_app_environment + key_vault). The identity → role_assignment →
  container_app chain is unrunnable: the smalt ARM face returns no
  `properties.clientId/principalId` for userAssignedIdentities (documented
  UNSUPPORTED attr roundtrip), so computed-attr chaining cannot satisfy TF's
  fully-known-after-apply law. Face defaults pinned in config for zero-drift.
- Court script fixes (orchestration only): stage 1 polls `/metadata/endpoints` (bearer-gated
  `/healthz` would SKIP forever); falsifier containerApps GET pinned to `2023-05-01`
  (2024-03-01 → 400); residue check scoped to court-owned RG names (shared subscription);
  stage 7 reworked to apply→plan→destroy since stage 6 legitimately tears down the stack.

## Session-introduced lib/ fixes (disclosed; each beyond the "scripts-only" lane boundary,
## each required for the ladder to run at all, each marked in-source)

1. `lib/tfprovider_smalt/encoding.ex` — unknown sentinel was `Msgpax.Ext.new(0, "value")`
   → wire `C7 05 00 "value"`; go-cty expects fixext1 `D4 00 00`. TF rejected with
   `["id"]: unsupported extension type 0x00 with len 5`. Now `@unknown_payload <<0>>`.
   Empirically verified both encodings under the vendored msgpax.
2. `lib/tfprovider_smalt/core/apply.ex` — apply ctx never carried `config`; create/update
   read `ctx.config` as nil ("Missing required argument: name"). Now `config: planned`.
3. `lib/tfprovider_smalt/server.ex` + `core/read.ex` — refresh tuple mismatch:
   `read/1` returns `{:ok, state, private}`, handler matched `{:ok, state}` → raise on every
   refresh. Normalized.
4. `lib/tfprovider_smalt/server.ex` (`apply_resource_change`) — several resources return
   response diagnostics as the 3rd tuple element; the proto field is bytes. List privates
   are now carried as response diagnostics (converted via `to_diag/1`).
5. `lib/tfprovider_smalt/schemas.ex` — `attr_type_atom/1` flattened every non-list proto
   attr type to `:string` (bools/numbers/maps served as strings; TF
   `["tags"]: string is required`). Now parses the cty JSON (bool/number/map/list).
6. `lib/tfprovider_smalt/schemas.ex` (`normalize_block_attrs`) — container types were
   double-wrapped under `:type`; unwrapped.
7. `lib/tfprovider_smalt/server.ex` (`decode_dv!`) — null DynamicValues on the destroy
   face (nil/empty msgpack) raised; now decode to nil.
8. `lib/tfprovider_smalt/server.ex` (`null_dv`) — `Msgpax.pack!(nil)` iolist in a proto
   `:bytes` field failed protobuf encode on destroy plan; now `IO.iodata_to_binary/1`.
9. `lib/tfprovider_smalt/server.ex` (`resp/2`) — only matched diag lists; ARM errors
   `{:arm_error, status, body}` raised FunctionClauseError inside the gRPC handler
   ("Internal Server Error" with no diagnostic). Catch-all clauses added.
10. State-shape law: `to_state` must carry every schema attribute. Removed nil-dropping in
    `to_state` paths (`schemas/{container_app_environment,container_registry,
    log_analytics_workspace,storage_account}.ex`, `resources/{container_app,key_vault,
    key_vault_secret}.ex`, `resources/generic.ex` delete now returns null state,
    `resources/resource_group.ex`/`key_vault.ex`/`key_vault_secret.ex` deletes return
    `{:ok, nil, ""}`), and `resources/generic.ex` `prior_state/1` now also reads
    `ctx[:prior_state]` (Core.Read's key) so refresh resolves identity fields.
11. `lib/tfprovider_smalt/resources/generic.ex` delete / bespoke deletes — return null
    new state, not `%{}`/`removed_state` (TF "Provider produced invalid object" /
    "object with 9 attributes is required (1 given)").

A byte-shim approach (rewriting the unknown sentinel in the TLS proxy) was built and
REJECTED: the rewrite changes payload length inside HTTP/2 DATA frames and corrupts
framing. The encoding fix must live in the provider.

## Diagnostics method (for replay)

Crashes were invisible over the wire (no gRPC stdio service). Root-caused by (a) driving
`Server.*` handlers in-process under `mix run` with encoded DynamicValues, (b) capturing
h2 frames in the mTLS proxy + HPACK-decoding gRPC trailers, (c) capturing BEAM stdout
(logger writes to standard_io in escripts) via the wrapper's handshake file.

## Falsifiers

- Court exit is fail-closed: any stage FAIL → exit 1 (observed many times this session —
  the court flips RED readily; not a vacuous gate).
- Second consecutive clean-state run reproduced GREEN (non-flake evidence).
- Substrate 401 `SignatureVerificationFailed` was observed once on a concurrent-create
  burst; the subsequent run passed 20/20 curl probes. Flagged as substrate-side transient,
  unexplained, not reproduced since; provider retries did not exist and were not needed.

## Replay

```
tar -xzf ~/smalt/tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz -C /tmp/f2-provider
cd /tmp/f2-provider/terraform-provider-smalt
bash scripts/build_install.sh            # escript + AutoMTLS wrapper + rc
source scripts/tf_env.sh                 # optional env wiring
bash scripts/provider_court.sh           # expect: 8/8 PASS, exit 0
```

Requires: kind substrate up on 127.0.0.1:9443, terraform 1.14, go-plugin mTLS stack in
`bin/` + `tools/tls_proxy.py` (extracted tree includes them post-run; a fresh archive
extraction would need the wrapper/tfrc/proxy files copied from this receipt's tree).
