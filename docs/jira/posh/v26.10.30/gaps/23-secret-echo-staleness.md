# 23 — Secret-Echo Staleness Sweep (KV secret GET now echoes properties.value)

Status: **ALIVE** — live wire probe executed this session (receipt below); every
artifact asserting "never-echoed" swept; two stale-asserts fixed in place; the
echo is classified as a real-Azure divergence (opposite polarity of the
registered KD-03), not a regression of a removed strip — the ARM child face
never had a value strip; it renders the stored record verbatim.

## Substrate behavior change (witnessed live, 2026-10-30)

Live probe (`mix run --no-start` + real Bandit HTTP on 127.0.0.1:19523, real STS
client_credentials token, real wire PUT/GET, api-version 2021-11-01):

- vault PUT -> 202
- secret PUT -> 201, response body `properties.value` = `probe-secret-value`
- secret GET -> 200, body contains `properties.value: "probe-secret-value"`

**VERDICT: ECHOED** (exact echo of the PUT value) on
`GET /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.KeyVault/vaults/:v/secrets/:s`
(`resource_providers.ex:3026` → `handle_child_get` at `:1009` renders the
`build_resource_record` output verbatim; `build_resource_record` stores the PUT
payload's `properties` verbatim, so `properties.value` round-trips).

Probe source: `/tmp/kv_echo_probe.exs` (session scratch). Store started via
`Smalt.Store.start_link([])`; probe ran under the lane build root
`_build-lane23` (lane lease, deleted below).

## Classification: divergence, not regression

- The ARM child GET (`handle_child_get`, `resource_providers.ex:1009-1044`)
  renders the stored record verbatim and has no secret-specific `value` strip;
  the child PUT (`:977`) stores `properties` verbatim. There is no evidence of
  a removed strip (single squashed commit `f0e0a125` covers the file's git
  history, so blame cannot date a strip; none exists in the current code).
- Real Azure's ARM control-plane GET of a secret does **not** return
  `properties.value` (the value is only served by the Key Vault *data plane*).
  The substrate's echo is therefore a parity divergence with polarity opposite
  to the one KD-03 registered — it must stay registered, with the corrected
  divergence text.
- The Elixir data-plane engine (`lib/smalt/data_plane/key_vault/secrets.ex:112`)
  correctly strips `value` from its public record — the never-echoed claim is
  TRUE on the 8443 data-plane face and on deleted-secret bundles. Only the ARM
  control-plane child face echoes.

## Per-artifact decisions

| Artifact | Decision | Action |
|---|---|---|
| `posh/KNOWN_DIVERGENCES.md` KD-03 | stale-assert (premise inverted) | FIXED in place this session: row rewritten to the current disjunctive reality |
| `adapters/terraform-provider-smalt/internal/provider/live_f4_test.go` | stale comment, body already disjunctive | FIXED in place: header comment updated |
| `.../resource_key_vault_secret.go:365-368` Read | fine (disjunctive: adopts echoed value, else keeps prior state) | no change |
| `.../resource_key_vault_secret.go` schema/comment "write-only" | fine (describes the provider contract, not the substrate) | no change |
| `live_f4_test.go:323-333` raw-GET disjunctive law | fine (omits-OR-echoes-exactly, both typed) | no change |
| `live_f4_test.go:481` container-app "wire secret echoed value" fatal | fine (container-app secrets surface — distinct face, still never-echoed; out of this lane's probe scope, not re-verified) | no change |
| `lib/smalt/data_plane/key_vault/secrets.ex:112` public record drop | fine (data plane strips value — correct) | no change |
| `posh/scripts/coverage.py` | no KV-secret echo cells exist | no change |
| `docs/jira/posh/v26.10.30/gaps/01-provider-azurerm-parity.md` | no never-echoed claim | no change |
| `docs/jira/posh/v26.10.30/gaps/07-secrets-identity.md` | no never-echoed claim | no change |
| Elixir archive (archived provider) | SKIPPED per lane contract | — |
| v26.10.14 `KNOWN_DIVERGENCES.md` KD rows | no KV-secret echo row found (KD-03 there is blob last-modified, unrelated) | no change |

## Fixes landed this session

1. `posh/KNOWN_DIVERGENCES.md` KD-03 — divergence text now states the
   disjunctive law: the ARM control-plane face echoes `properties.value`
   (witnessed 2026-10-30); the data-plane face never echoes; the provider Read
   adopts an exact echo or preserves prior state; container-app wire secrets
   remain never-echoed (distinct face).
2. `live_f4_test.go` header comment — "never echoed" replaced with the
   disjunctive wording the test body already enforced.

Close condition (unchanged in spirit): ARM face omits `properties.value` on
GET (real-Azure parity), or the echo is accepted-and-registered (current
disposition). Either is typed; silent re-flip in either direction is the
failure class.
