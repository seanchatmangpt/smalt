# W6AZ — Event Hubs CAPTURE parity (JSONL sink over real BlobStorage)

**Standing:** ALIVE (module tier)

## What landed

- `lib/smalt/messaging/eh_capture.ex` (NEW) — per-hub opt-in capture
  description (account/container/name_format/interval_seconds/
  size_limit_bytes; at least one trigger required, typed ArgumentError
  otherwise). Per-(hub, partition) buffering in heir'd ETS
  `:smalt_eh_capture` (3-tuple `{:heir, Process.whereis(:init), []}`,
  lazy start). Flush = one JSONL capture blob per partition into smalt's
  REAL BlobStorage with metadata {x-ms-meta-hub, partition,
  FirstSequence, LastSequence, Count}; JSONL body byte-exact.
- Flush triggers: size (after each enqueue) and interval (GenServer-owned
  Process.send_after timers, re-armed after each flush). Whichever fires
  first.
- No-loss: failed put_blob retries once; persistent failure keeps the
  buffer and fires [:smalt, :event_hubs, :capture_write_failed] telemetry.
- Disabled faces: enqueue under disabled capture → {:error,
  :capture_disabled}; disable cancels the timer and removes the desc row
  (buffered events kept).

## Azure parity boundary (honest)

Real Azure Event Hubs Capture writes AVRO capture files. This emulator
writes JSONL — a documented divergence, NOT claimed as avro. nameFormat
tokens {hub}/{partition}/{yyyy-MM-dd-HH-mm-ss} render at flush time.

## Witness (real output)

Replay: MIX_BUILD_ROOT=_build-lane-w6az MIX_ENV=test mix run --no-start tmp/w6az_witness.exs

F0_DISABLED=true
F1_BLOB_EXISTS=true
F1_JSONL_BYTE_EXACT=true
F1_SEQ_META=true
F2_INTERVAL_FLUSH_SECOND_BLOB=true
F2_BUFFER_DRAINED=true
F3_DISABLED_REFUSED=true
F4_NO_TRIGGER_400=true
F4_BAD_INTERVAL_400=true
F4_BAD_SIZE_400=true
F5_EMPTY_FLUSH=true
W6AZ WITNESS: ALL FACES OK

## Verification ladder

- Full-tree mix compile: GREEN (a sibling quota_usage.ex corruption
  self-repaired by its owner mid-window).
- Internal tier: 48 tests, 0 failures.
- Chunked-heredoc discipline: the >150-line single-Write corruption class
  hit this lane twice; both caught by per-chunk syntax gates and rebuilt.

## Falsifier

Witness legs that would be vacuous if broken: F1 byte-exact JSONL,
F0/F3 disabled faces, F5 empty-buffer face. Green under a broken
implementation would require all three to also be broken.

## Disclosures

- Minimal disclosed unblock: `String_t()` → `String.t()` typo in
  lib/smalt/arm/sb_management.ex (w6aj's landed file, no active owner).
- Probe-script bugs (uppercase-var match, stale-beam precedence) were
  witness-side only; no lib/ changes from them.
- Lane build root _build-lane-w6az left for coordinator lane-clean.
