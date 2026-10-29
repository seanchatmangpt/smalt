# KD-174D2 — KD-174 falsifier probe + typed OPEN disposition

- **Lane**: KD-174D2 (registrar; prior KD-174D lane died pre-landing on a 429 — its
  /tmp/kd174d probe artifacts were reused, not re-authored)
- **Date**: 2026-10-22
- **Standing**: PARTIAL_ALIVE (probe executed and witnessed; row remains OPEN by
  design — the falsifier witnessed a fail-closed refusal, not conformance)
- **Context**: solo
- **Subject**: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-174 row (cells:
  witness + falsifier + disposition), this receipt

## Probe (real client, real listener)

Real kafka-python-ng 2.2.3 (vendored at `tmp/kafkalib`, same library BK-122r used)
against the smalt Kafka wire face booted fresh (`MIX_ENV=test`,
`MIX_BUILD_ROOT=_build-kd174d2`, ephemeral port from the app itself).

1. **ApiVersions v0** — matrix served (raw socket, exit 0):

   ```
   APIVERSIONS ec=0 matrix=[[0, 0, 2], [1, 0, 2], [2, 0, 1], [3, 0, 1], [18, 0, 0]]
   ```

   Produce capped at v2 ⇒ infers broker (0,10,0) ⇒ real clients ride magic-0/1.

2. **Magic-2 produce attempt** — `KafkaProducer(api_version=(0,11,0), ...)` pinned
   HIGH so the client emits Produce v3 with magic-2 RecordBatch regardless of the
   advertised matrix:

   ```
   PRODUCE-REFUSED KafkaConnectionError: socket disconnected
   LIVENESS ok (listener still serving after probe)
   OUTCOME REFUSED
   ```

3. **Broker side** — typed crash-only kill in the boot log:

   ```
   05:29:25.803 error[] [kafka] CRASH-ONLY kill: {:unsupported_version, 0, 3}; connection closed
   ```

   `LIVENESS ok` shows the kill is per-connection, fail-closed — never a parse
   guess. Listener kept serving afterwards.

## Disposition

The row's typed posture (**deliberate legacy-face parity scope**) is honest:
magic-2 produce is genuinely refused fail-closed for a real client path, and the
served legacy surface was already byte-verified field-by-field against
kafka-python's parsers in AZ-1c. The falsifier ("a real client negotiates magic-2
produce with a witness receipt") is NOT satisfied — the probe witnessed the
refusal, which is the OPEN posture's claim, not closure evidence. **KD-174 stays
OPEN (registered), now falsifier-witnessed.** No flip. Owner remains the BK-122r
kafka-parity lane; next action unchanged (advertise Produce v3+ with matching v3
record shapes, then flip via `scripts/kd_flip.py --apply`).

## Register edit

KD-174 row only: witness cell now cites this receipt with the probe summary;
disposition standing updated to "OPEN (registered, falsifier-witnessed as
fail-closed refusal 2026-10-22)". Other cells untouched.

## Commands

```
mix compile (MIX_ENV=test MIX_BUILD_ROOT=_build-kd174d2) → 0 errors
mix run --no-halt /tmp/kd174d/boot.exs → KPORT=55683
python3 /tmp/kd174d/probe.py 55683 → EXIT=0, transcript above
```

Compile-freeze disclosure: none needed this window (maa.ex was mid-break earlier;
the owner lane's fix had landed before my compile).

## Falsifier (still open, unchanged)

A real client negotiating magic-2 produce through this listener with a witness
receipt — requires the v3+ face, not a register edit.
