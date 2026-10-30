# Known Divergences — v26.10.31 (pointer)

Canonical KD register: [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md)
(the table is ground truth). Mint from **KD-189** (highest minted id is
KD-188, minted 2026-10-30 by the wave-2 kd-registrar lane). This doc
REGISTERS; it does not close. Flips only via `scripts/kd_flip.py --apply`,
gated on a PASS witness receipt postdating the shim mtime.

## Register structure change this window

The canonical table gained a **`dialect` column** (second column): every
row classifies as `AZURE-#1` (Azure wire-parity surface) or `CORE`
(smalt/BEAM-substrate law row, not an Azure-wire divergence). Defaults were
applied mechanically and verified per-row (no blind sed); the 5 CORE rows
are KD-168/174/177/178/179, read before stamping: MAA gate law, Kafka wire
face, hardware-anchored trust class row, Web PubSub supervision split, AMQP
SAS loopback parse — none is an Azure-wire-parity divergence.

## Rows minted this window

- **KD-187** — ARM-container/blob-face container-namespace disconnect
  (kd-registrar lane 18; mirror at
  `lib/smalt/arm_gateway/plug/resource_providers.ex:935-963`, `# KD-COVERS:
  KD-92`): local-substrate probe at current code answers 201 end to end —
  KD-92 holds; the courtroom KIND-pod disconnect was a stale-image artifact
  (foreign-tenant token namespace reproduced both the 403 and 404 arms
  in-session). Status: CLOSED-OBSOLETE (stale-image witness). Receipt:
  `receipts/kd187-stale-image-falsifier.md`.
- **KD-188** — ARM storage managementPolicies child route absent
  (registration-only row): `PUT .../managementPolicies/default` → 404
  `RouteNotFound` (live re-witness 2026-10-30); zero `managementpolic*`
  matches in `lib/`. Status: OPEN. Evidence:
  `receipts/kd187-stale-image-falsifier.md` (KD-188 leg) +
  `/Users/sac/cai/courtroom-platform-az/receipts/hrn004-crmh-harness.md`
  (TC-CRMH-002).

## Renumbering note

The v26.10.29 ash-wave DRAFT rows KD-187/188/189 were renumbered to
KD-190/191/192 (never minted in the canonical register; renumbering
annotated inline in
[`../v26.10.29/ash-wave-resolutions.md`](../v26.10.29/ash-wave-resolutions.md);
original draft ids preserved in git history).
