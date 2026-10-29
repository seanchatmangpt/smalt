# PQC Client-Side SHACL Admission (design, saved 2026-10-23)

Source: benchmark finding — SHACL validation is ~96% of compile_turtle
(~2.86 ms median; benches/sql_rdf_compiler.rs). Move validation to the
client; server verifies a witness.

- Client runs SHACL eval locally, proves closed-world conformance, signs
  (H_doc, ShapeDigest, WitnessReceipt) with ML-DSA/Dilithium or Falcon.
- Server: PQC verify + digest check → microseconds; fail-closed at
  ingress; no server-side parse/AST allocation for invalid frames.
- Zero-trust: proof-carrying queries; state machine verifier only.
- Evidentiary: quantum-resistant receipts (BCBS 239 / DvP long-tail
  non-repudiation, FRE 902(14)); anchor in Sigma_PQC.
- Prereq: ring cache keyed ahead of validate_ast_shacl (cache-miss path
  otherwise re-validates). Baseline: benches/sql_rdf_{compiler,admission}.rs.
- Target window: v26.10.23+ (post 26.10.22 publish). Ticket as
  SQLRDF-27-class when the window opens.
