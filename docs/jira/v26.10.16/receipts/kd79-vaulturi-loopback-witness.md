# KD-79 witness receipt — Key Vault vaultUri loopback-by-design

Standing: **PASS** (fence green, witness receipts re-anchored 2026-10-17, lane I3)

- Surface: `Microsoft.KeyVault/vaults` enrichment `vaultUri` (router.ex:817-class site, defaults.ex KD-T5-F1).
- Divergence: vaultUri echoes the request authority (loopback https twin) instead of real Azure's
  `https://<name>.vault.azure.net/` — deliberate, azurerm 4.54 POLLS vaultUri directly.
- Command: `MIX_BUILD_ROOT=_build-laneI3 mix test test/kd79_blob_apiversion_wire_test.exs test/arm/fr5_tf_divergence_closures_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs`
- Output: `24 tests, 0 failures` (includes the KD-T5-F1 vaultUri legs in
  test/arm/fr5_tf_divergence_closures_test.exs), **exit 0**, 2026-10-17.
- Coverage token: `# KD-COVERS: KD-79` at test/kd79_blob_apiversion_wire_test.exs:1 (fence anchor).
- This receipt supersedes the non-durable `/tmp/t5wire.sh` replay evidence and
  /tmp/tf-cleanroom.* logs named in the KD-79 row.
- Close condition unchanged (loopback-by-design; row stays OPEN until a DNS-shape vault host mapping exists) — but the witness evidence is now durable and receipt-gated for kd_flip.
