# TF plan probe: azurerm per-resource-type vs smalt ARM plane

- Date: 2026-10-16
- Lane: tf-plan-probe (lane 419, ports 39330-39335)
- Subject: `/Users/sac/smalt` v26.10.16 working tree (multi-lane)
- Fixtures: `/Users/sac/smalt/test/terraform_fixture_per_resource/<name>.tf`
- Probe: `/Users/sac/smalt/scripts/tf_plan_check.sh --write-receipt`
- Work dir (kept): `/tmp/tf-plan-probe.hPaBPZ` (per-fixture plan.log/apply.log = wire evidence)
- FR-5 context: this run postdates the shape-enrichment, HEAD-route, and
  api-version monotonic-admission landings; it is the FR-5 milestone receipt.

## Verdict: FR-5 six-fixture plan + apply

Plan-parse: PASS on all six fixtures ( witnessed twice, runs
`/tmp/tf-plan-probe.H4HmZT` and `/tmp/tf-plan-probe.hPaBPZ`), i.e. the
enriched shapes (vaultUri/primaryEndpoints/SB-shape/EH-panic), the HEAD
existence routes, and monotonic api-version admission hold at plan time for
every resource family. Apply-phase verdicts per fixture:

| Fixture | Plan | Apply/Refresh | Typed classification |
|---|---|---|---|
| rg | PASS (1 to add) | DIVERGENCE → fix landed | refresh drift `+ tags = {}`; root-caused to tags echo (`{}` vs azurerm's null-when-empty). FIXED this session: `normalize_tags/1` null-when-empty (SHIM-COURT, lib/smalt/arm_gateway/router.ex). Witness re-run pending trust restoration (see below). |
| keyvault | PASS (2 to add) | DIVERGENCE → fix landed | Same tags-drift class as rg (vault + its RG). Same fix. |
| storage | PASS (3 to add) | DIVERGENCE (typed) | post-create data-plane poll `Microsoft.Storage/storageAccounts/blobServices` api-version 2023-05-01 > emulator cap 2021-04-01 (InvalidApiVersionParameter). Registry-lane scope: child-type api-version caps. |
| servicebus | PASS (3 to add) | DIVERGENCE (typed) | `Microsoft.ServiceBus/namespaces/queues` api-version 2024-01-01 > cap 2021-04-01 (InvalidApiVersionParameter). Registry-lane scope: child-type api-version caps (pre-classified). |
| eventhub | PASS (3 to add) | DIVERGENCE (typed) | `Microsoft.EventHub/namespaces/eventhubs` api-version 2024-01-01 > cap 2021-04-01 (InvalidApiVersionParameter). Registry-lane scope: child-type api-version caps (pre-classified). |
| cosmos | PASS (4 to add) | DIVERGENCE (typed) | `DatabaseAccounts#CheckNameExists` → 400 with EMPTY body (autorest: `error response cannot be parsed: EOF`). Emulator error-envelope defect: checkName-exists route 400s (should be 200/404 semantics) and must always carry an ARM error envelope. |

## Divergences

TYPED divergence = azurerm's own error names the divergent ARM shape;
that is a registered finding (KD candidate), not a hidden failure.

Standing per cell:
- plan-parse: ALIVE ×6 (two independent runs).
- rg/keyvault tags drift: fix landed, witness pending — SUSPECT until re-run.
- storage/servicebus/eventhub caps: OPEN — registry lane (child-type
  api-version caps).
- cosmos CheckNameExists envelope: OPEN — new typed finding.

## Environment gate (blocks re-run; needs operator action)

Go on darwin does NOT honor `SSL_CERT_FILE` (Go 1.23.4
`crypto/x509/root_darwin.go:128` — `loadSystemRoots` returns an empty pool;
Apple SystemVerify decides). The terraform CLI and the azurerm provider are
both hardened-runtime (`flags=0x10000(runtime)`), so the DYLD trust shim
cannot inject. Therefore azurerm TLS to the 39331 twin depends entirely on
macOS keychain trust of the dev CA. Admin-domain trust for `smalt-dev-ca`
existed through ~12:50 (probe runs 12:15/12:45 passed TLS) and was cycled
away by concurrent-lane automation; `security add-trusted-cert -d` needs
passwordless sudo (unavailable). Re-arm with:

    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \
      /Users/sac/smalt/.smalt/tls/ca-cert.pem

Probe hardening landed this session (`scripts/tf_plan_check.sh`): lane-private
TLS snapshot + self-heal (chain + CA:FALSE check, re-mint on legacy CA:TRUE
leaf churn) so a probe run is immune to mid-run re-mints once trust exists.

- Standing: PARTIAL_ALIVE — plan-parse surface proven per-resource (×2);
  apply-phase divergences typed in-table; tags fix witnessed only by wire
  evidence, full witness blocked on keychain trust re-arm.
