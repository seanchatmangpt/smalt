# KD-81 witness receipt — LRO terminal poll body carries resource identity

Standing: **PASS** (fence green, 2026-10-17, lane I3)

- Surface: `lro_wire_body/1` render-time enrichment, lib/smalt/arm_gateway/router.ex (`# KD-COVERS: KD-81` token at the first clause).
- Command: `MIX_BUILD_ROOT=_build-laneI3 mix test test/arm/fr5_tf_divergence_closures_test.exs test/kd79_blob_apiversion_wire_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs`
- Output: `24 tests, 0 failures` (includes the KD-T5-F3 "storage LRO terminal poll body carries the resource identity" leg), **exit 0**, 2026-10-17.
- Coverage token: `# KD-COVERS: KD-81` at lib/smalt/arm_gateway/router.ex (lro_wire_body/1).
- Supersedes the non-durable `/tmp/t5wire.sh` replay evidence named in the KD-81 row.
