# Receipt: BK-SKEP adversarial skeptic re-audit of the AMQP10 wire front-end

**Standing**: PARTIAL_ALIVE
**Context**: solo
**Lane**: BK-SKEP, repo /Users/sac/smalt, read-only (receipt only)
**Subject**: `lib/smalt/messaging/amqp10/frame_decoder.ex` (post-EXPL-4-F2 repair),
court `test/internal/wire_exp4_court_test.exs`, receipt
`wire-exp4-frame-decoder.md`

## Method

Read-only skeptic audit. Decoder compiled standalone to /tmp scratch beams
(`/tmp/bkskep_amqp10`, `elixirc frame_decoder.ex` — EXPL-4 precedent, no
shared-build dependency, no tree writes). Real hand-built binary frames pushed
through the public `decode_frame/1` boundary; raises captured with `catch`.
No mocks, no sleeps, no git state commands.

## A. Landed claims — re-verified

All EXPL-4 F2 falsifier legs re-run independently (not by re-running the
court test — fresh adversarial probes against the same surface):

```
== A. Landed-claim re-verification ==
A1 truncated sized elements (7 classes): ALL-OK
A2 0xC0/D0/C1/D1 declared-size binding: ALL-OK
A3 non-vacuity: bin8=OK c0-list=OK
A4 proper-prefix leg: ALL-OK
```

- A1: all 7 sized constructors (0xA0/A1/A3/B0/B1/B3/0x98) with declared len
  200 / 5 bytes present answer `{:error, :truncated_frame}` — CONFIRMED.
- A2: 0xC0/D0/C1/D1 truncation → `:truncated_frame`; trailing bytes inside
  the declared slice → `:bad_element` — CONFIRMED.
- A3: full payloads decode (200-byte string → attach name; 0xC0 list → OK) —
  the court is non-vacuous on this class.
- A4: every proper prefix of a valid frame answers a tagged tuple.

Moduledoc spot-checks that PASS as claimed: bounds via guards (not
raise/rescue) confirmed by construction read + probe; heartbeat, doff=1
refusal, size<8 refusal, 0xB0 declared 0xFFFFFFFF refusal — all typed.

## B. NEW defects found (the repair missed one)

### F1 — CONFIRMED: odd element count in 0xC1/0xD1 maps raises FunctionClauseError

`frame_decoder.ex:415-423` (`map_exact/3` → `pairs/1`): `pairs/1` has clauses
`pairs([])` and `pairs([k, v | t])` only. `take_exact/3` happily returns an
odd-length list when the declared count is odd and the slice is exact — and
then `pairs/1` blows up with an untyped `:function_clause` that propagates
through the public `decode_frame/1`.

Probes (hostile frames riding as first positional field of an attach):

```
legal map: {:ok, %{performative: {:attach, %{name: %{{:symbol, "k"} => nil}, ...}}}, ""}
C1 count=1 single nil (odd, exact): {:RAISED, :error, :function_clause}
D1 count=1 single nil (odd, exact): {:RAISED, :error, :function_clause}
C1 count=3 three nils (odd, exact): {:RAISED, :error, :function_clause}
```

Bytes: `0xC1, 2, 1, 0x40` / `0xD1, 5::32, 1::32, 0x40` / `0xC1, 4, 3, 0x40*3`
inside `<<size::32, 2::8, 0::8, 0::16, 0x00, 0x53, 0x12, ...>>`. Note the
count semantics are lawful here: the codec encodes count = keys+values
(2×pairs, `lib/smalt/messaging/amqp/primitive_codec.ex:178,232`), the decoder
decodes `count` elements — a legal 1-pair map decodes fine (probe above). The
raise is reachable only with a spec-INVALID odd count, but the moduledoc law
(frame_decoder.ex:14-16, receipted in wire-exp4) is categorical: "decode
never raises on remote input". The wire-exp4 court has no odd-count leg —
coverage gap.

Blast radius: `amqp10_connection.ex:162` (`pump_frames/2`) has no rescue — a
hostile peer kills the connection process with untyped `function_clause`
instead of the crash-only typed `{:exit, {:bad_frame, _}}`. Crash-only design
survives the death, but the receipted typed-decode claim is falsified.

Minimal repair (one line-class): in `map_exact/3`, refuse odd lists —

```elixir
defp map_exact(count, elems, outer_rest) do
  case take_exact(count, elems, outer_rest) do
    {:ok, list, rest} when rem(length(list), 2) == 0 -> {:ok, Map.new(pairs(list)), rest}
    {:ok, _, _} -> {:error, :bad_element}
    {:error, _} = err -> err
  end
end
```

### F2 — minor, typed but misleading reason codes

Out-of-range declared sizes fall through to the truncation fallback and
answer `:truncated_frame` where the real fault is the size itself:

```
B5 C0 size=0:        {:error, :truncated_frame}   (spec-invalid, not truncation)
B6 D0 size=2 (<4):   {:error, :truncated_frame}
B15 B0 declared 0xFFFFFFFF: {:error, :truncated_frame}
```

Still typed, never raises — cosmetic mislabel, no law violated. Optional
tightening: a size-out-of-bounds fallback answering `{:error, :bad_element}`
(or a `:bad_constructor_size` reason).

## C. Checked and found sound

- `decode_elements/3` recursion: every element constructor consumes >= 1
  byte, so recursion depth is bounded by the declared slice (< max_frame_size)
  — no unbounded loop on `count=0xFFFFFFFF` (B7: `{:error, :bad_element}`).
- Deep nesting: 60k nested generic-described `0x00` → typed `:error` (B8);
  500k nil-element list → typed (B9). No stack exhaustion on hostile frames.
- Zero-length edges: 0xC1 count=0 → `{}` map, 0xC0 count=0 → `[]`, 0xB1
  empty string — all decode; heartbeat frame decodes; SASL frame on nonzero
  channel decodes (channel not validated against SASL — noted, not a defect
  under crash-only routing).
- Connection-level: sub-header fragments buffer (`{:more, _}`), partial
  protocol-header prefix law holds (read, lines 146-155).

## Verdict

Landed EXPL-4 F2 claims: all re-verified. Standing PARTIAL_ALIVE because F1
is a live, one-frame remote-reachable untyped-raise on the same wire surface
the repair receipt declares closed ("decode never raises on remote input" —
falsified by a spec-invalid odd-count map). F2 is cosmetic. Recommend F1 as a
follow-up work order with the odd-count leg added to
`test/internal/wire_exp4_court_test.exs`.

## Reproduce

```
cd /tmp/bkskep_amqp10 && elixir probe.exs   # A-legs + B-legs
cd /tmp/bkskep_amqp10 && elixir probe5.exs  # F1 minimal witnesses
```

(scratch beams: `elixirc /Users/sac/smalt/lib/smalt/messaging/amqp10/frame_decoder.ex -o /tmp/bkskep_amqp10`)
