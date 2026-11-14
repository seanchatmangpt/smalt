# GS4 Secrets and KMS Census

Standing: UNVERIFIED

Existing primitives: `lib/smalt/data_plane/key_vault/{keys,secrets,hsm}.ex`
(Store-table backed, Azure dialect), `mhsm.ex` (release policy), `security/`
(attestation, receipt signer). Their API is Store-coupled, so the GCP dialects
are self-contained Agent-state modules using `:crypto` directly (AES-256-GCM,
ECDSA P-256), mirroring Key Vault semantics (versions, soft state, rotation).
Not yet bridged to Key Vault Store tables.
