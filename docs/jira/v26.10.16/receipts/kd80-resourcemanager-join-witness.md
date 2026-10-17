# KD-80 witness receipt — metadata resourceManager trailing-slash join semantics

Standing: **PASS** (fence green, 2026-10-17, lane I3)

- Surface: metadata endpoint doc `resourceManager` emission, lib/smalt/arm_gateway/router.ex (`# KD-COVERS: KD-80` token at the `"resourceManager" =>` line).
- Divergence: resourceManager emitted WITHOUT trailing slash; azurerm joins verbatim with "/subscriptions/..." (no TrimSuffix) — deliberate join-semantics deviation, loopback-by-design.
- Command: `MIX_BUILD_ROOT=_build-laneI3 mix test test/arm/fr5_tf_divergence_closures_test.exs test/kd79_blob_apiversion_wire_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs`
- Output: `24 tests, 0 failures` (includes the KD-T5-F2 metadata legs), **exit 0**, 2026-10-17.
- Supersedes the non-durable `/tmp/t5wire.sh` replay evidence named in the KD-80 row.
