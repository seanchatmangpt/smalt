# GS4 Secret Manager and Cloud KMS Dialects

Standing: UNVERIFIED

Authoring lane: no mix/just/git run. Nothing compiled or tested.

## Files
- lib/smalt/gcp/secret_manager.ex (Smalt.GCP.SecretManager)
- lib/smalt/gcp/kms.ex (Smalt.GCP.KMS)
- test/gcp/secrets_kms_secret_manager_test.exs
- test/gcp/secrets_kms_kms_test.exs
- docs/gcp-parity/GS4-secrets-kms-census.md

## Wiring
Router forwards `/v1/projects/*/secrets*` to
`Smalt.GCP.SecretManager.handle(pid, method, path, query_map, body_map)` and
`/v1/projects/*/locations/*/keyRings*` to `Smalt.GCP.KMS.handle/5`; both return
`{status, json_map}`. Start each with `start_link/0` under the application
supervisor, e.g. `{Smalt.GCP.SecretManager, ...}` via a child spec wrapper
`%{id: SM, start: {Smalt.GCP.SecretManager, :start_link, []}}`.

## Gaps
Not bridged to Key Vault Store tables; first compile may need fixes.
