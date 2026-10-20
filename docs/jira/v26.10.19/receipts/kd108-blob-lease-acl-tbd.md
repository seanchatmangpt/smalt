# kd108-blob-lease-acl-tbd.md — evidence skeleton (kd-registrar, 2026-10-19)

- **KD row**: KD-108 (blob container lease/ACL absent)
- **Standing**: UNKNOWN (skeleton — no embedded command output yet; will be flagged SUSPECT by receipt_index until witnessed)
- **What would witness**: A BlobLeaseClient acquires, renews, and releases a container lease, and setAccessPolicy/getAccessPolicy roundtrip a signed identifier — probe output shows all legs 2xx and the ACL read-back matching the set.
- **Falsifier**: acquire/renew/release lease + set/get container ACL roundtrip passes

Pending command (exact): `just substrate-up` then run the BlobLeaseClient
witness probe (acquire/renew/release lease + setAccessPolicy/getAccessPolicy
roundtrip, falsifier above) against the booted substrate — **BLOCKED during
in-flight court**: requires a substrate boot, forbidden while a court is in
flight. Witness lane runs it post-court and re-embeds output here.

Context: solo (registrar mint; witness run pending)
