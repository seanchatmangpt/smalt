# S-3 Receipt — KD-15 KV Challenge Auth (v26.10.15, execution lane S-3)

Subject: KD-15 landed per explore design E-3a on the canonical smalt checkout.
Status: CLOSED-with-receipt. No commits (per dispatch).

## Diffs (handwritten)

1. `lib/smalt/auth/bearer.ex` — `refuse/3` now emits the enriched challenge via
   new public `challenge_value/2` + `send_challenge/2`:
   `Bearer authorization="<sts-authority>/organizations", resource="<request origin>", error="invalid_token", error_description="<reason>"`.
   Grammar constraint honored: `authorization` (NOT `authorization_uri` — not in
   the keyvault-common `parseWWWAuthenticate` whitelist) and `resource` (must
   echo request origin — `keyVaultAuthenticationPolicy.js verifyChallengeResource`
   hostname check). `:smalt, :sts_authority_url` override supported; default
   `<scheme>://<host>:<arm_port>/organizations` (tenant segment present so the
   SDK derives tenantId from the URL path).
2. `lib/smalt/egress_router.ex` — mode-blind `:kv_challenge_guard` plug mounted
   before `Smalt.Auth.Bearer` (:49): `/keys*` + missing/empty Authorization →
   401 + enriched challenge in BOTH auth modes. CORS preflight (OPTIONS)
   exempt (method-mismatch court pins OPTIONS /keys/k1 → 404). Enforce mode
   still refuses invalid tokens downstream (unchanged).

## Mutation court — scripts/shim_court/kv_challenge_court.sh — PASS

Witness: `test/sdk-full/kv_challenge_witness.mjs` (real `@azure/keyvault-keys`
KeyClient, no injected Authorization header, `disableChallengeResourceVerification: true`
— documented SDK option required for IP-endpoint vaults).

- BEFORE (enrichment stripped to plain challenge + guard passthrough):
  `[witness:BEFORE] HANDSHAKE_FAIL RestError: MissingBearerToken` — the policy
  finds no `resource` in the parsed challenge, cannot attach a token, the 401
  propagates. exit 1.
- AFTER: `[witness:AFTER] HANDSHAKE_OK kd15-chal kid=present` — two-step
  challenge handshake completed on a live enforce-mode substrate (private
  ports; canonical ports under concurrent-lane contention). exit 0.
- RESTORE: sha256-verified byte-identical (`sha256sum -c` OK) + EXIT-trap
  restore so FATAL paths can no longer leak the mutation.

Court hardening added during the run (defects found by execution):
- degraded-snapshot guard (grep KD-15 markers in the snapshot before accepting;
  an earlier FATAL-without-restore chain had degraded the snapshot to the
  mutated variant and silently neutralized restores — caught by the AFTER-phase
  witness failing identically to BEFORE).
- private-port substrate (arm/egress/tls/mcp/amqp/eh all randomized — the
  substrate's MCP listener (:9545), AmqpBroker (:5672/:5673) are FIXED-port and
  collide with concurrent lanes' substrates; canonical-port substrate_up raced
  other lanes' windows).
- TLS env surface copied from scripts/substrate.sh (SMALT_TLS_CERTFILE/KEYFILE,
  SSL_CERT_FILE, NODE_EXTRA_CA_CERTS).

## Re-test (final, post-repair tree)

`mix test test/egress_dispatch_test.exs test/auth_enforce_test.exs test/data_plane/key_vault_actions_test.exs`
→ 258 tests, 3 failures, none KD-15/auth-owned:
- 2x SKR release 403 (`egress_dispatch_test.exs:294`, `:261`) — A/B-verified
  failing at HEAD lib (git-show snapshot swap) before any KD-15 edit: pre-existing.
- 1x cosmos continuation 400 (`egress_dispatch_test.exs:1593`) — cosmos-lane
  mid-flight churn (ReadFeed envelope shape flip-flopping across runs).

New fence: KD-15 401-with-params courts x2 (anonymous + enforce mode) in
`test/egress_dispatch_test.exs` — tokenless GET /keys → 401 with
`authorization=`/`resource=`/`error="invalid_token"`/`error_description=`,
no `authorization_uri`; non-/keys routes unchanged.

Harness adaptation (disclosed): `egress_dispatch_test.exs call/3` now attaches
a placeholder Authorization header on /keys calls ("already-challenged client")
because the mode-blind guard correctly 401s tokenless calls; three raw-builder
tests (content-type fuzz, Accept matrix, method mismatch) got the same explicit
header. `Bearer egress-harness-challenged-client`.

sdk-smoke `arm.test.cjs` challenge test (starts-with-Bearer match) → PASS
(1/1) against a live enforce-mode substrate.

## Environment incidents (disclosed)

- Killed orphan beam pid 82232 (42-min-old private-port substrate holding the
  global substrate lock via inherited fd — the dod-01 defect class; parent
  window dead, starving all lanes; `just substrate-down` could not clear it).
- Three shared-compile freezes from other lanes' in-flight files
  (management_rpc.ex, frame.ex, virtual_serial.ex, connection.ex) — waited out
  per compile-freeze SLA; no unblock fixes applied to others' files.

## Standing

ALIVE on the court witness (two-step handshake over real SDK + live TLS
substrate, both modes fenced in ExUnit).
