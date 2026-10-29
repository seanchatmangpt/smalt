# KD-BLOB: blob error-contract court for the KD-131..154 window

**Standing:** ALIVE — court green 12/12 over real HTTP (real Bandit TCP listener on an
ephemeral port, real `:httpc` requests, assertions on wire bytes); all blob rows in
the window read CLOSED on disk in the canonical register; this receipt documents the
regression fence, no flip owed.
**Context**: solo

## Subject

`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` KD-131..KD-154, blob rows KD-135..KD-146.
Register re-read at use time (2026-10-22): every row KD-131..KD-154 is CLOSED
(CLOSED-WITH-RECEIPT / CLOSED-SIMULATED / CLOSED-WITH-EVIDENCE / PINION) — the register
is ahead of the dispatch brief, which anticipated an OPEN blob row. No OPEN blob
error-contract row exists in the window.

## Court (new fence)

`test/internal/kd_blob_court_test.exs` — one court leg per fixed shape:

| leg | shape | wire pin |
|---|---|---|
| KD-136 | GET blob, no x-ms-version | 400, XML, `x-ms-error-code: MissingXMsVersion` |
| KD-137 | GET x-ms-range past EOF | 416 InvalidRange |
| KD-138 | GET container comp=bogus | 400 InvalidQueryParameterValue (real-Azure pinion) |
| KD-139 | PUT blob, no x-ms-blob-type | 400 MissingRequiredHeader |
| KD-140 | PUT blob, no Content-Length (raw socket) | typed 400/411 refusal, never silent 0-byte 201 |
| KD-141 | invalid x-ms-meta header (raw socket) | refused typed 400, never 500 (Bandit transport guard) |
| KD-142 | systemic envelope (asserted on every error leg) | `<?xml …><Error><Code>…</Code>…` + `x-ms-error-code` + `x-ms-version` + uuid `x-ms-request-id` |
| KD-144 | Create Container ETag | quoted `0x…` hex, empty body |
| KD-145 | Put Blob 201 | EMPTY body (no JSON debug envelope) |
| KD-146 | blob ETag | quoted `0x…` hex, byte-equal across PUT/GET |
| KD-135 | blob DELETE, default container | 202 Accepted (real-Azure); WORM `ContainerLocked` reserved for policy-bearing containers |
| scope | KV face | JSON envelope survives (blob XML is face-scoped) |
| control | legal PUT + ranged GET | 201/206 byte-equal + `content-range` — refusals are not an always-refuse gate |

## Verification (embedded output)

```
$ MIX_BUILD_ROOT=_build-kdblob asdf exec mix test test/internal/kd_blob_court_test.exs
Finished in 0.2 seconds (0.00s async, 0.2s sync)
Result: 12 passed
```

Neighbor fences re-run, no regression:

```
$ MIX_BUILD_ROOT=_build-kdblob asdf exec mix test test/integration/blob_xml_error_test.exs test/data_plane/blob_hardening_test.exs
Finished in 0.1 seconds (0.00s async, 0.2s sync)
Result: 9 passed
```

## Findings

1. **No OPEN blob row to close** — the window's blob rows were closed by the
   v26.10.20/21 lanes (BK-18 flipped KD-142 with a live-wire witness,
   `docs/jira/v26.10.21/receipts/bk18-blob-error-contract.md`). The lane's
   deliverable is the durable regression court, not a re-close.
2. **KD-135 pinion premise stale on current HEAD** (pre-existing, disclosed): the
   row's pinion claims wire-created containers default `immutable: true`
   (blob_storage.ex:157) so SDK blob deletes 409. The live wire answers
   **202 Accepted** on blob DELETE against a default container (containers created
   with `immutable` defaulting false, blob_storage.ex:178-180). Current behavior is
   *more* Azure-aligned than the pinion (real Delete Blob = 202). The pinion text,
   not the wire, is the residual drift — register-side only, no code change owed.
3. **KD-141 guard is at the transport layer**: Bandit rejects the malformed
   `x-ms-meta-meta data!` header line with a bare HTTP/1.0 400 before the router
   runs — the census-era smalt-500 shape is structurally unreachable. Pinned as
   "refused typed, never 500, at whichever layer".

## Environment

Elixir 1.20.4-otp-29 (asdf exec; homebrew mix on PATH is 1.19.5 and fails the
`~> 1.20` gate), MIX_BUILD_ROOT=_build-kdblob. One compile-freeze window on shared
`lib/smalt/messaging/kafka/records.ex` (another lane's in-flight edit) observed and
waited out — no unblock edit applied.
