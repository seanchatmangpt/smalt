# Receipt — R121 (kd_flip covers-map dry run)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `scripts/kd_flip.py` — the registrar's dry/default mode now prints the
  KD-COVERS covers-map (per-KD status + covering files), so the register's
  flip state is inspectable without a write.

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ python3 scripts/kd_flip.py; echo "KDEXIT=$?"
KD-COVERS covers-map: 9 KD ids from 11 files
  KD-03: [CLOSED-WITH-RECEIPT] lib/smalt/data_plane/blob_service.ex
  KD-15: [CLOSED-WITH-RECEIPT] lib/smalt/auth/bearer.ex, lib/smalt/egress_router.ex
  KD-18: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-21: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-49: [CLOSED-with-receipt] lib/smalt/messaging/amqp/connection.ex
  KD-52: [CLOSED] lib/smalt/data_plane/blob_storage.ex, lib/smalt/data_plane/cosmos.ex
  KD-53: [CLOSED-SIMULATED] lib/smalt/messaging/event_hubs.ex
KDEXIT=0
```
