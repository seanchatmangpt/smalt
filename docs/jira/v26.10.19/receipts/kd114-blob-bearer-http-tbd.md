# Receipt — KD-114 blob data-plane auth channel (bearer-over-http refused)

Standing: **UNKNOWN** (evidence skeleton, TBD; witnessed FAIL, no fix)
Context: full
Lane: kd-registrar; no lib/ edits.

## Divergence

Blob data plane has no usable official-SDK channel under enforce auth:
core-rest-pipeline refuses to send a Bearer credential over plain http, the
emulator's enforce-mode Bearer plug refuses SharedKey, and blob is not routed
on the 9444 TLS twin — so every official-SDK blob auth path dead-ends.

## Witnessed evidence (verbatim from the wf receipt)

`docs/jira/v26.10.19/sdk-results/wf2-ts-multistore-concurrency.md`
(SUBJECT_SHA b847c020ee6b0a7ef426e27379f960228932feb0, 2026-10-19):

```
[FAIL] blob-auth-channel — SharedKey refused by enforce-mode Bearer plug;
bearer-over-http refused by the SDK itself; blob not routed on the TLS twin —
no usable official-SDK blob channel under enforce auth
```

Cell tag: `blob-auth-channel: FAIL`. Non-SDK SharedKey paths remain exercised
by the blob unit/wire tests; the divergence is the official-SDK channel only.

## Close condition / falsifier

Blob routed on the TLS twin (or a SharedKey admit path consistent with real
Azure) such that an official SDK `BlobClient` upload/download roundtrip passes
under enforce auth. Falsifier: `just sdk-ts` blob cell GREEN — SharedKey or
bearer-over-TLS upload → list → download byte-equal.

## Related

KD-15 (KV challenge handshake is the working TLS-twin pattern).
