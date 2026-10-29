# BK-29 — KD-79 closure: loopback vaultUri constant re-witnessed on wire

**Standing:** PASS (CLOSED-WITH-EVIDENCE; constant holds, adversarial leg refuses the wrong shape)
Context: solo
Date: 2026-10-22
HEAD: 8261a43548d53af7d4a92b76d05e5cc267780c71
Substrate: UP pid 53160 (already up; no boot owed, lock FREE)
Lane build root: MIX_BUILD_ROOT=_build-bk29 (declared; not used — no compilation needed)
Supersedes disposition: docs/jira/v26.10.21/receipts/bk11-kd-legacy-triage.md (KD-79 row)

## What the row pins

KD-79 (register `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, line 262):
`Microsoft.KeyVault/vaults` enrichment emits `vaultUri` echoing the gateway
request authority (loopback-normalized) instead of real Azure's
`https://<name>.vault.azure.net/` — deliberate, because azurerm 4.54 polls
vaultUri directly and the public-DNS form dead-ends ("no such host").
Code face: `lib/smalt/arm_gateway/defaults.ex:30-54` (`enrich_defaults/0`,
KD-T5-F1 comment block, localhost→127.0.0.1 normalization, `vaultUri` =
`"#{vault_uri}/"`), wired through router PUT persist (`build_resource_record`).

## Wire evidence (real substrate, real HTTP, exact commands + exits)

Token (TLS twin 9444, HS256 from emulator STS):

    curl -s -X POST "https://127.0.0.1:9444/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token" \
      --cacert .smalt/tls/ca-cert.pem \
      -d grant_type=client_credentials -d client_id=bk29 -d client_secret=bk29 \
      -d scope=https://management.azure.com/.default
    -> 200, access_token len 1353

Leg 1 — constant holds (generic ARM provider route, router.ex:6511):

    curl -X PUT "http://127.0.0.1:9443/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/bk29rg/providers/Microsoft.KeyVault/vaults/bk29kv?api-version=2023-02-01" \
      -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
      -d '{"location":"eastus","properties":{"tenantId":"00000000-...","sku":{"family":"A","name":"standard"},"accessPolicies":[]}}'
    -> 202 InProgress (op id c9f0420b54100a5100084d5b)
    bounded poll op status -> Succeeded (poll 1)
    first GET hit a store-write race (row visible to the list feed, single GET
    404 once) -> immediate re-GET:
    GET vault -> 200
    properties.vaultUri = http://127.0.0.1:9443/

The vaultUri echoes the request authority (loopback, port 9443) — the pinned
constant holds. Matches the BK-11 witness value exactly
(`vaultUri http://127.0.0.1:9443/`), on a fresh vault at HEAD 8261a43.

Leg 2 — adversarial (probe refuses the wrong shape): the constant's known
hazard is a `localhost` authority dialing [::1] from Go clients (comment block
defaults.ex:43-45, witnessed azurerm forever-loop). The probe sends the PUT
with a `localhost` request authority via `--resolve localhost:9443:127.0.0.1`:

    curl --resolve localhost:9443:127.0.0.1 -X PUT "http://localhost:9443/.../vaults/bk29kv-adv?api-version=2023-02-01" ...
    -> 202 -> bounded-poll GET 200
    properties.vaultUri = http://127.0.0.1:9443/
    assert "localhost" not in u and "::1" not in u  -> PASS (exit 0)
    assert u.startswith("http://127.0.0.1:")        -> PASS

If the normalization constant were absent/wrong, the emitted vaultUri would
carry `localhost`/`[::1]` and the assertion leg exits nonzero — the probe
REFUSES. It did not refuse because the wire answered with the pinned constant.

## Falsifier status (unchanged)

The row's falsifier — azurerm keyvault apply reaching terminal without
"no such host" — is NOT run here and remains satisfiable only once the
emulator gains a DNS-shape vault host mapping; at that point the constant
flips to the real `<name>.vault.azure.net` form. Closure type is
CLOSED-WITH-EVIDENCE (documented design constant, re-witnessed live with an
adversarial refusal leg), not CLOSED-SIMULATED.

## Flip mechanics

`scripts/kd_flip.py --apply` was considered and NOT used: it flips only
OPEN→CLOSED-SIMULATED for rows whose id appears in a `# KD-COVERS` shim in
`lib/`; KD-79's site is marked `KD-CANDIDATE (KD-T5-F1)` (defaults.ex:30), no
shim landed this lane, so no flip-eligibility exists. Closure is a registrar
edit of the status cell, receipt-gated by this file.

## Cleanup

No lane build root created (no compile). /tmp/bk29.tok removed.
