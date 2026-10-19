# kd107-blob-snapshots-tbd.md — evidence skeleton (kd-registrar, 2026-10-19)

- **KD row**: KD-107 (blob snapshots partial)
- **Standing**: UNKNOWN (skeleton — no embedded command output yet; will be flagged SUSPECT by receipt_index until witnessed)
- **What would witness**: A blob probe creates a snapshot, lists snapshots on the blob, and reads back snapshot content at the snapshot timestamp — probe output shows create + list + read-back all 2xx with matching bytes.
- **Falsifier**: SDK snapshot probe: create → list → read-at-snapshot roundtrip passes

Context: solo (registrar mint; witness run pending)
