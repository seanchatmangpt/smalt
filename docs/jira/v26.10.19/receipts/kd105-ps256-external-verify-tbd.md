# kd105-ps256-external-verify-tbd.md — evidence skeleton (kd-registrar, 2026-10-19)

- **KD row**: KD-105 (PS256 not externally verifiable)
- **Standing**: UNKNOWN (skeleton — no embedded command output yet; will be flagged SUSPECT by receipt_index until witnessed)
- **What would witness**: An external verifier (Node WebCrypto crypto.verify with RSA-PSS/sha256) validates a substrate PS256 signature against the public JWK — probe output shows verify = true and a tampered-payload control verify = false, exit 0.
- **Falsifier**: Node crypto.verify('sha256', ...) = true on the probe flow against the exported public JWK; tampered control = false

Context: solo (registrar mint; witness run pending)
