# GS5 Receipt

Standing: UNVERIFIED

Authoring lane: nothing compiled or run (no mix/just/git).

Files: lib/smalt/gcp/identity.ex, iam.ex, router.ex; test/gcp/identity_plane_test.exs;
docs/gcp-parity/GS5-identity-census.md.

Wiring (shared file, not edited), in `Smalt.ArmGateway.Router` before `plug(Smalt.Auth.Bearer)`
(and before `Smalt.ArmGateway.Plug.ReceiptTurnstile` if GCP responses need no ARM receipts):

    plug(Smalt.GCP.Router)

Notes: tokens stateless RS256 (per-VM key in persistent_term); IAM roles table is
viewer/editor only; Resource Manager lives in iam.ex

