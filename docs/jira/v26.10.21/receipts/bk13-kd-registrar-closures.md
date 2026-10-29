# Receipt: BK13 — KD registrar-closure lane (KD-135 / KD-136 / KD-138)

- **Date**: 2026-10-21 (lane BK13, build root `_build-bk13`)
**Standing**: ALIVE
- **Context**: solo
- **Scope note**: at lane start the canonical register
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) already carried all three rows
  as CLOSED-WITH-RECEIPT (KD-135 flipped by lane B-K2/B-KD's witness
  `docs/jira/v26.10.20/receipts/bkd-kd135-137-139-witness.md`; KD-136/KD-138
  closed by registrar parity pinion, no shim owed). This lane therefore
  performed **independent re-verification** of each close condition against
  the current code/substrate, plus one adversarial re-check per closure. No
  flip was owed (`scripts/kd_flip.py`: FLIP-ELIGIBLE 0 in scope; KD-135 shown
  `[CLOSED-WITH-RECEIPT]`; the single FLIP-PENDING-WITNESS row, KD-157, is
  out of lane scope). This receipt (postdating the KD-135 shims,
  mtime 2026-10-21 10:23/10:24) re-anchors the closures.

## Environment

- Substrate booted via `MIX_BUILD_ROOT=_build-bk13 9>&- scripts/substrate.sh up`
  (fresh lane build root; first boot drained into a full deps compile,
  ~4 min bounded poll to 8443 UP after 231s; second boot after a foreground
  `mix compile` warm-up). Data plane 127.0.0.1:8443, STS 9443.
- Bearer minted from emulator STS: `POST /dev/oauth2/v2.0/token`
  (client_credentials) → 1263-char token, exit 0.
- All requests carry `x-ms-version: 2021-08-06` unless the shape under test
  is its omission (KD-136).

## KD-135 — verdict CLOSED-WITH-RECEIPT (re-verified ALIVE)

Close condition: SDK-expressible delete path on a default (non-WORM) container.

```
PUT  /devstoreaccount1/bk13-probe?restype=container  → 201
PUT  /devstoreaccount1/bk13-probe/del.txt (BlockBlob) → 201
DELETE /devstoreaccount1/bk13-probe/del.txt           → 202 Accepted
```

PASS — matches the bkd-kd135-137-139 witness exactly. Close condition holds.

**Adversarial re-check (must refuse)**: same delete against a WORM-opt-in
container (`x-ms-immutable-policy: true`):

```
PUT  /devstoreaccount1/bk13-worm?restype=container (x-ms-immutable-policy: true) → 201
PUT  .../del.txt → 201
DELETE .../del.txt → 409 Conflict, x-ms-error-code: ContainerLocked
```

The probe flips — a default-container delete is 202 while a WORM delete is
409 ContainerLocked: the closure is not vacuous (the delete path is
conditional on the immutability class, exactly the typed divergence). Cleanup
note: container `bk13-worm` delete also correctly 409s (WORM container
deletion refused); the container name remains reserved in that ephemeral
substrate instance only (substrate since stopped).

## KD-136 — verdict CLOSED-WITH-RECEIPT (re-verified ALIVE)

Close condition (as re-typed): smalt answers the real-Azure contract —
400 MissingXMsVersion on a versionless blob GET.

```
GET /devstoreaccount1/bk13-probe/no-ver.txt   (no x-ms-version)
HTTP/1.1 400 Bad Request
x-ms-error-code: MissingXMsVersion
<Error><Code>MissingXMsVersion</Code>…</Error>   (StorageError XML)
```

PASS — real-Azure contract answered (400 on missing required header).

**Adversarial re-check (must not 400)**: same GET **with**
`x-ms-version: 2021-08-06` against a real blob:

```
PUT .../ver.txt → 201
GET .../ver.txt (with x-ms-version) → 200, body "0123456789"
```

The 400 is conditional on the missing-header class, not a blanket refusal —
the probe can fail; closure is non-vacuous.

## KD-138 — verdict CLOSED-WITH-RECEIPT (re-verified ALIVE)

Close condition (as re-typed): smalt answers 400 InvalidQueryParameterValue
for `comp=bogus` (real-Azure contract; azurite's 200-ignore was the
mis-configured leg).

```
GET /devstoreaccount1/bk13-probe?restype=container&comp=bogus
HTTP/1.1 400 Bad Request
x-ms-error-code: InvalidQueryParameterValue
<Error><Code>InvalidQueryParameterValue</Code><Message>The comp value 'bogus' is not supported (GAP(blob-comp-lease-absent))…</Message></Error>
```

PASS — real-Azure contract answered.

**Adversarial re-check (must not 400)**: `comp=metadata` → 200;
`restype=container` without `comp` → 200. The refusal is specific to the
invalid-comp class; closure is non-vacuous.

## Registrar summary

| KD | Close condition (current code) | Close probe | Adversarial mutation | Verdict |
|---|---|---|---|---|
| KD-135 | SDK-expressible delete on default container | 201/201/**202** | WORM delete → **409 ContainerLocked** | CLOSED-WITH-RECEIPT (re-verified) |
| KD-136 | 400 MissingXMsVersion on versionless GET | **400** + x-ms-error-code header | with-version GET → **200** | CLOSED-WITH-RECEIPT (re-verified) |
| KD-138 | 400 InvalidQueryParameterValue on comp=bogus | **400** + x-ms-error-code header | comp=metadata → **200**; no-comp → **200** | CLOSED-WITH-RECEIPT (pre-existing) |

- kd_flip state at lane end: `python3 scripts/kd_flip.py` → FLIP-ELIGIBLE: 0,
  FLIP-PENDING-WITNESS: 1 (KD-157, out of scope). Exit 0.
- Cleanup: `bk13-probe` container deleted (202); `bk13-worm` delete 409
  (WORM posture — expected refusal); substrate down (ports free);
  `/tmp/bk13-token.txt` removed.
- Not committed (per lane contract).
