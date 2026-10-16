# ROTATION-PENDING-SIGNATURE (2026-10-15)

Signing key rotated 2026-10-15 (see docs/jira/v26.10.14/receipts/rotate-signing-key.md,
new seed sha256 prefix fa9ea5ea45923395). The receipt chain in this directory
(`receipt.json`, `receipt-log.jsonl`) is still signed with the RETIRED key
(old seed sha256-of-seed prefix recorded in the rotation receipt; old seed
eradicated from tree — zero grep hits). Signatures were NOT rebuilt: reproducing
this chain requires re-running the original `ggen sync` against the original
ontology/manifest state. Leave chain bytes intact until re-signing.

- Status: ROTATION-PENDING-SIGNATURE
- Old chain bytes: UNCHANGED (do not edit; JSONL chain hashes are position-sensitive)
- New keypair: ../.ggen/keys/ (cli/.ggen/keys at repo root)
