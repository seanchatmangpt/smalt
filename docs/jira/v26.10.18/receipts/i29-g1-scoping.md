# i29 — G1 Queue Storage Scoping Receipt

Standing: PASS (feasibility probe; no lib/ or test/ edits)

Context: solo(lib/ + docs/ grep probe; no mix test invocation)

- Date: 2026-10-18. Target: docs/jira/v26.10.18/azsim-burn/G1-QUEUE-STORAGE-SCOPING.md (landed verbatim from the Plan-lane output).

## Findings
1. No Azure Queue Storage REST surface exists (grep: 0 hits for PopReceipt/visibilitytimeout/azqueue). SB AMQP stack is a distinct surface.
2. G1 needs popreceipt issuance/rotation, visibilitytimeout re-appearance, stale-replay 404 PopReceiptMismatch.
3. Effort: data_plane/queue_storage.ex + egress_router route arm (blob-splat disambiguation is the one real risk) + 2 StoreTables rows + queue_storage_test.exs + wire pins.
4. KD/GAP law: no GAP token lane-side; coordinator mints residual tokens after the WIRE_PARITY row lands (KD-04 precedent).
