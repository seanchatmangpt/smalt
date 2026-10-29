# JSONSAX — stream/3 discard-style SAX helper on Smalt.JsonCompat

Context: solo

- **Date**: 2026-10-21
- **Lane**: JSONSAX (writer, OTP-29)
- **Subject**: `lib/smalt/json_compat.ex` @ HEAD 85e5cbd... (working tree
  byte-identical to HEAD; coordinator tick checkpoint 8defcf5 landed the
  final courted state)
- **Standing**: ALIVE
- **Context**: solo

## What landed

`Smalt.JsonCompat.stream/3` — discard-style SAX streaming decode wrapping
the REAL T42-verified native API (`json:decode_start/3` +
`json:decode_continue/2`, arity-specific hook funs: container-start
arity-1, array-push arity-2, object-push arity-3, finish arity-2). The
folklore `:json.decode/3` map-of-handlers form is absent, as SNIPPET-REVIEW
required.

Delivery contract (documented in @doc):

- top-level array -> elements dispatched exactly once, in order, element-wise
  (bounded heap: the element frame is dropped after dispatch)
- top-level object/scalar -> delivered whole on completion
- concatenated top-level values (NDJSON/unseparated) each delivered (the
  decoder's leftover input restarts as a fresh decode_start)
- `{:ok, count}` | `{:ok, count, values}` with `opts[:accumulate]` |
  `{:error, {:malformed_json, reason}}` (ErlangError from `:json`
  (:invalid_byte, :unexpected_end, ...) rescued and typed.

Implementation notes (executed-API facts, each witnessed by a probe in this
session):

- `:json.decode/3` (whole-input with decoders) exists but raises
  `:unexpected_end` under non-trivial hook accs — the stream form is
  decode_start/decode_continue only, as T42 pinned.
- Scalar hooks have native defaults (`binary_to_integer/float`); only
  container lifecycle + `null: nil` needed overriding.
- A bare trailing scalar ("1 2 3") is only terminated by whitespace;
  the drain path flushes one JSON-space terminator (can only complete,
  never corrupt, a truncated stream).
- Truncated input (`{"i":0` unterminated) → typed
  `{:error, {:malformed_json, :unexpected_end_of_input}}`; the one-space
  flush cannot flip truncated into delivered.

## Court (7/7 PASS, OTP 29.1.2, Elixir 1.20.4-otp-29)

Runner: /tmp/jsonsax_court.exs (real :json decoder, real processes);
ExUnit court `test/json_compat_stream_test.exs` (11 tests) + existing
`test/json_compat_test.exs` (5) = 16/16 pass, MIX_BUILD_ROOT=_build-jsonsax.

```
corpus: 8787222 bytes, 50000 docs, 3 chunks (2921559/2932700/2932963)
C1 exactly-once count:  {:ok, 50000}  (80 ms)  PASS
C2 corpus equality:     uniq=true inorder=true  PASS
C3 peak heap:           92736 bytes (0.09 MiB), count=50000, <1MiB=true  PASS
C4 malformed:           {:error, {:malformed_json, {:invalid_byte, ...}}}  PASS
C5 truncated:           {:error, {:malformed_json, :unexpected_end_of_input}}  PASS
C5b empty:              {:error, {:malformed_json, :empty_input}}  PASS
C6 contract:            ndjson=true object=true scalars=true null=true  PASS
VERDICT: 7/7 PASS
```

50k-doc synthetic array in 3 chunks: every doc delivered exactly once,
in order; peak process heap 92,736 bytes < 1MB budget (worker +
1ms-tick process_info sampling — bounded poll, no-sleep compliant).

## Machine

`just bench-machine` (host): {"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
Court toolchain: asdf OTP 29.1.2 + Elixir 1.20.4-otp-29 (.tool-versions pin), MIX_BUILD_ROOT=_build-jsonsax.

## Failures during the run (honest log)

- Corpus bug (doubled commas from map_join "," + leading ",") — fixed in
  harness, not module; surfaced as typed {:invalid_byte, 44}.
- Lane build froze twice on concurrent lanes' in-flight edits
  (amqp10/frame_decoder.ex, smalt_fond_powl_runner.erl); waited out per
  compile-freeze SLA, no fixes applied to other lanes' files.
- No test failures in the landed subject; 16/16 pass, 0 errors.

## Replay

```
export PATH=~/.asdf/installs/elixir/1.20.4-otp-29/bin:~/.asdf/installs/erlang/29.1.2/bin:$PATH
cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-jsonsax mix test test/json_compat_stream_test.exs test/json_compat_test.exs
# standalone court: runner preserved at /tmp/jsonsax_court.exs
```

## Re-verification 2026-10-21 (backlog bk3 lane, reconciles — not a duplicate receipt)

Standing: ALIVE (re-confirmed)

Fresh cold-build re-run on `lib/smalt/json_compat.ex` @ HEAD f4b9028e3158
(working tree byte-identical; `git diff --stat` empty for the file),
MIX_BUILD_ROOT=_build-bk3.

```
$ MIX_BUILD_ROOT=_build-bk3 mix test test/json_compat_stream_test.exs test/json_compat_test.exs
Finished in 3.7 seconds (0.2s async, 3.5s sync)
Result: 16 passed        # exit 0
```

Adversarial (script /tmp/jsonsax_bk3_adversarial.exs, `mix run --no-start`,
exit 0; --no-start required: bare `mix run` boots the app and collides with
a running substrate on port 8443):

```
BIG>1MB: ok count=200000 first=1 last=200000 bytes=1288896
MALFORMED-MID-STREAM: {:error, {:malformed_json, {:invalid_byte, 111}}}
TRUNCATED-MID-DOC: {:error, {:malformed_json, :unexpected_end_of_input}}
```

- 1.29 MB single top-level array, 4KB chunks: 200k elements delivered
  exactly once, in order.
- invalid byte mid-stream (chunk boundary at 7 bytes) and truncation
  mid-document (5-byte chunks) both stay typed
  `{:error, {:malformed_json, reason}}`, no raise, no partial dispatch.

Replay:

```
export PATH=~/.asdf/installs/elixir/1.20.4-otp-29/bin:~/.asdf/installs/erlang/29.1.2/bin:$PATH
cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-bk3 mix test test/json_compat_stream_test.exs test/json_compat_test.exs
MIX_BUILD_ROOT=_build-bk3 mix run --no-start /tmp/jsonsax_bk3_adversarial.exs
```
