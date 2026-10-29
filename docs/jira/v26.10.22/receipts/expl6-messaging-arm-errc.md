# EXPL-6 — ERRC read-only sweep: `messaging/amqp/` (v1 front-end), `storage/`, `arm_gateway/` (non-router)

**Standing:** PARTIAL_ALIVE
Context: solo
Date: 2026-10-22
Lane: EXPL-6 (read-only explore; only this receipt written)

## Scope

Surfaces not yet covered this milestone: `lib/smalt/messaging/amqp/` (v1 AMQP
front-end; amqp10 already covered), `lib/smalt/storage/` (journal surfaces
beyond EXPL-5's data_plane scope), `lib/smalt/arm_gateway/` (beyond the KD-143
sb-rules fix). Defect classes: fail-open on absent/malformed input, untyped
MatchError/FunctionClauseError on remote/corrupt input, best-effort silent
drops, success answers on unknown resources, unauthenticated faces neither
gated nor KD-registered, premise rot. Receipted findings (INDEX + KD register
v26.10.14 through KD-170, incl. KD-127..134/143/153..157 on these surfaces)
were excluded; uncommitted-drift check per lane contract included.

## Uncommitted-drift check (lane contract)

- `lib/smalt/messaging/kafka/conn.ex` — was dirty in the session-start git
  status snapshot; `diff <(git show HEAD:...) working-tree` returned EMPTY at
  probe time: the working tree is byte-identical to HEAD now (drift since
  committed or reverted). No audit split needed.
- `lib/smalt/webpubsub/` — `git status --porcelain` empty. Clean.

## Findings (ranked)

### F1 (HIGH, witnessed) — JournalReader: corrupt sealed segment raises untyped MatchError instead of a typed refusal

`lib/smalt/storage/journal_reader.ex`

- F1a, `parse_frames/4` line ~202: the frame-header pattern
  `<<@magic::binary, frame_len::unsigned-integer-size(32), _::binary>> = binary_part(...)`
  is an UNGUARDED match. A segment whose first bytes are not `"SMAL"` (bit rot,
  truncation, adversarial bytes) that is still >= 8 bytes total escapes
  `read_sealed_segment/1` as a raw MatchError — exactly the escape the
  moduledoc's "never a MatchError escape" comment (decode_one/extract_fields)
  claims cannot happen: the rescue sits in `extract_fields/1`, one layer BELOW
  the two unguarded header matches.
- F1b, `decode_one/3` line ~233: `frame_len` is only bounded by `needed > have`;
  `body_size = frame_len - 4` is never checked >= 0. `frame_len` in 0..3 gives
  a negative binary segment size → MatchError (witnessed) instead of a typed
  `{:truncated_frame, ...}` refusal. F1c (`"SMAL"` only, 4 bytes) is correctly
  typed `{:truncated_tail, ...}` — so the two unguarded windows are the entire
  gap between the doc's law and the code.
- Class: untyped crash on corrupt (potentially adversarial) input on the
  replay path; contradicts the module's own fail-closed law ("INTEGRITY
  failures ... typed boot refusals"). A corrupt segment turns boot replay from
  a typed refusal into a crash.
- Witness (real compiled-module probe, `mix run --no-start`,
  MIX_BUILD_ROOT=_build-expl6, Elixir 1.20.4-otp-29, scratch beams only — no
  substrate, no tree writes; build root deleted after):

```
F1a bad-magic    -> RAISED MatchError: no match of right hand side value: <<88,88,88,88, ...>>
F1b tiny-framelen -> RAISED MatchError: no match of right hand side value: <<...>>
F1c magic-only   -> {:error, {:truncated_tail, [offset: 0, have: 4]}}   # correctly typed
```

- Repair ticket EXPL6-1: bound the header match in `parse_frames/4`
  (`<<@magic::binary, frame_len::..., _::binary>>` -> `case` with typed
  `{:bad_magic, offset: offset}` refusal) and add `frame_len >= @crc_len`
  (4) to the `needed > have` guard in `decode_one/3`'s caller, mapping both to
  the existing `{:truncated_frame, ...}` / a new typed `{:bad_magic, ...}`
  refusal vocabulary; add court legs for bad-magic and framelen<4 segments.
  ~10 lines, no wire change (reader-only; sealed segments written by the sink
  are always well-formed, so this is strictly a corrupt-input hardening).

### F2 (HIGH, witnessed) — JournalSink: `seal(matter_scope: unused_scope)` crashes the sink with CaseClauseError

`lib/smalt/storage/journal_sink.ex:343-359` (handle_call `{:seal_scope, ...}`)

- `sc = Map.get(state.scopes, scope, new_scope_state())` — a scope never
  appended to synthesizes a FRESH state with `io: nil, frames: 0`, which
  matches `do_scope_seal(%{io: nil, frames: 0}, ...)` returning `{nil, sc}`.
  The call-site case has clauses `{meta, sc} when is_map(meta)` and
  `{:error, reason}` only; `{nil, sc}` matches neither → CaseClauseError,
  sink process crash (supervisor restart, in-flight scoped frames lost).
  Reachable by any caller sealing a scope before its first append — the exact
  "seal what you opened" race the seal protocol documents.
  (Legacy `:seal` is safe: `do_seal(%{io: nil, frames: 0})` → `{nil, state}`
  only reachable degraded, which is refused earlier — but see F3.)
- Witness (same probe rig; the crash killed the sink before the follow-up
  status call):

```
** (CaseClauseError) no case clause matching: {nil, %{io: nil, mode: :active, path: nil, bytes: 0, dropped: 0, next_seq: 0, reprobe_ms: 5000, degraded_reason: nil, frames: 0, sealed_count: 0}}
    (smalt 26.10.19) lib/smalt/storage/journal_sink.ex:348: Smalt.Storage.JournalSink.handle_call/3
    (stdlib 8.1.1) gen_server.erl:2470: :gen_server.try_handle_call/3
```

- Repair ticket EXPL6-2: add a `{nil, sc}` clause replying
  `{:error, :empty_segment}` (typed refusal, mirrors legacy `do_seal`'s
  `{nil, state}` contract) — or filter nil metas at both rotation call sites.
  ~3 lines.

### F3 (MEDIUM, code-cited, unwitnessed) — JournalSink: pre-write rotation crashes the sink when seal fails

`journal_sink.ex:409-417` (legacy) and `:751-765` (scoped `maybe_rotate_scope/4`)

- Both rotation legs `case do_seal(state) do {meta, st} when is_map(meta) -> ...`
  match the success shape ONLY; `do_seal` documents and returns
  `{:error, {:seal_failed, detail}}` on real filesystem conditions (rename
  collision, ENOSPC at stage). A seal failure during rotation is a
  CaseClauseError crash of the sink mid-append, violating the SPOF-A1 law
  ("the sink never raises on File errors") and losing the append the caller
  got `{:ok, seq}` promised for. F2's fix should be paired: handle
  `{:error, {:seal_failed, d}}` in both rotation legs (degrade + typed reply)
  instead of crashing.
- Repair ticket EXPL6-3: extend both rotation cases with an error clause that
  degrades (per SPOF-A1) and replies `{:ok, seq}`-drop or a typed error.
  ~8 lines.

### F4 (LOW, code-cited) — SasVerifier `sb:` audience wildcard

`lib/smalt/messaging/amqp/sas_verifier.ex:192`:
`audience_matches?("sb", _host, _port, _config), do: true` — a token minted
for ANY `sb://<anything>` audience verifies against ANY configured endpoint,
with skn `RootManageSharedAccessKey` or any rule key. This is an
air-gapped-loopback posture question (same class as KD-169's
"registered-open" row), not a witnessed exploit; the comment frames it as the
Service Bus resource form. Recommend a KD-register row (registration-only, KD
class like KD-169) rather than a code change: mint from KD-171.
- Repair ticket EXPL6-4: register the open face as a KD row
  (surface: `SasVerifier.audience_matches?/4` sb:-scheme wildcard; typed
  posture: deliberate loopback-open; close condition: host-scoped audience
  match with witness receipt, or re-registered stronger posture).

### F5 (INFO) — clean bills of health

Heavily hardened, no defects found beyond the above: `arm_gateway/lro.ex`,
`lro_notifier.ex`, `lro_sweeper.ex` (read, single-writer, deny-by-default
lens vocabulary present and consistent), `arm_gateway/defaults.ex`,
`provider_matrix.ex`, `messaging/amqp/cbs_router.ex` (F2 cap rework present),
`sas_verifier.ex` (parse/signature paths typed beyond F4),
`atom_bridge.ex` (i25/KD-51/KD-155 hardening present),
`namespace_usage.ex` (typed `:no_table` gate). Journal reader/sink laws
(SPOF-A1/A3, BK-135r scoping, quarantine telemetry) are otherwise correctly
implemented — F1/F2/F3 are edge-of-contract gaps in that fabric, not its
absence.

## Verification

- Probes: real compiled modules over the shared checkout, standalone
  `mix run --no-start` beam, `MIX_BUILD_ROOT=_build-expl6` (deleted at close
  per lane-cleanup law), scratch dirs under /tmp (deleted). No tree writes
  except this receipt.
- KD/premise check: KD register (canonical v26.10.14 table + v26.10.22
  pointer KD-169/170) scanned for amqp/storage/arm_gateway rows (KD-24..32,
  49, 68, 77, 81-92, 111-113, 124, 127-134, 143, 153-157, 169-170) — none of
  F1/F2/F3 overlap a registered divergence; F4 is a new KD-class posture row
  (mint from KD-171).
- Receipt-index law: embedded command output present for the witnessed
  findings.
