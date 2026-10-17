# KD-82 witness receipt — `*Services/default` singleton GET synthesis

Standing: **PASS** (fence green, 2026-10-17, lane I3)

- Surface: `storage_service_default_get/4` singleton synthesis, lib/smalt/arm_gateway/router.ex:2799 (single fix site on HEAD; `# KD-COVERS: KD-82` token added 2026-10-17).
- Command: `MIX_BUILD_ROOT=_build-laneI3 mix test test/arm/fr5_tf_divergence_closures_test.exs test/kd79_blob_apiversion_wire_test.exs test/arm/fr5_tf_divergence_closures_test.exs`
- Output: `24 tests, 0 failures` (includes the KD-T5-F4 "storage singleton service children synthesize real-ARM defaults" leg), **exit 0**, 2026-10-17.
- Coverage token: `# KD-COVERS: KD-82` at lib/smalt/arm_gateway/router.ex (storage_service_default_get/4).
- Supersedes the non-durable `/tmp/t5wire.sh` replay evidence named in the KD-82 row.
