# IMPL-23 — EEP-78 Comprehensions Probe (multi-element templates, single-pass 1-to-many)

Context: solo

- Date: 2026-10-21
- Repo: /Users/sac/smalt @ 34d091e45af0878e5439067e48a9b7fef7d5bd47
- Lane: probe only; no `lib/` changes; no bench jsonl emitted (not a bench lane).
- Machine: Apple M3 Max, macOS (Darwin 25.2.0), 16-core.

## 1. Availability

EEP-78 = comprehensions with multiple emitted elements per iteration
(`[E1, E2, E3 || X <- L]`, list template). Detected in OTP 29.1.2 via
`syntax_tools-4.1.1/src/erl_syntax.erl` (lines ~5710, ~5840: "Supports
comprehensions with multiple emitted elements per iteration, from EEP 78").

Compile probe (`eep78_probe.erl` with `multi/1 = [X, X*2, X*3 || X <- L]`):

| Toolchain | Result |
|---|---|
| Erlang/OTP 29.1.2 | COMPILES (exit 0) |
| Erlang/OTP 28.5.0.2 | `syntax error before: '||'` (exit 1) |

Note: the closest installed 28.x to the requested "28.3.1" is 28.3/28.5.0.2;
28.5.0.2 was used (no OTP 28 release carries the form — parse-level, not
version-patch-level).

## 2. Measurement (1M elements x 3 outputs = 3M-element result, min-of-5 wall, GC-run delta)

### Erlang, OTP 29.1.2

| Form | min-of-5 wall | GC runs delta | result length |
|---|---|---|---|
| `lists:flatmap(fun(X) -> [X,X*2,X*3] end, L)` | 50,142 us | 15 | 3,000,000 |
| EEP-78 comprehension (list template) | 48,965 us | 16 | 3,000,000 |
| `lists:append(nested-comp)` shape | 95,639 us | 6 | 3,000,000 |

### Erlang, OTP 28.5.0.2

| Form | min-of-5 wall | GC runs delta | result length |
|---|---|---|---|
| `lists:flatmap` | 50,960 us | 15 | 3,000,000 |
| EEP-78 comprehension | UNAVAILABLE (parse error) | — | — |
| `lists:append(nested-comp)` shape | 71,505 us | 6 | 3,000,000 |

flatmap is version-parity (50.1 vs 51.0 ms); the EEP-78 gain is additive on
29.1.2, not a flatmap rewrite.

### Codegen evidence (OTP 29.1.2, beam_disasm of eep78_probe.beam)

- `multi/1` (EEP-78 form): single `call_only` to its own lc helper
  `'-multi/1-lc$^0/1-0-'/1`, zero external calls — compiled single-pass, no
  `lists:flatmap`/`lists:append` lowering.
- `flat/1`: lowers to `{call_ext_only,2,{extfunc,lists,flatmap,2}}`.
- `comp/1` (append shape): lowers to `{call_ext_last,1,{extfunc,lists,append,1}}`.

## 3. Elixir side (1.20.4-otp-29 vs 1.19.0-otp-28)

Elixir `for` has no multi-output template syntax: a `do:`-block returns only its
last expression (compile warnings "result of operator '*'/2 is ignored" during
the probe; result len = 1,000,000, not 3,000,000). `for x <- l, do: [x, x*2, x*3]`
returns a list of lists (never flattens), so the EEP-78 single-pass 1-to-many
shape is not reachable from Elixir syntax.

| Form | 1.20.4-otp-29 | 1.19.0-otp-28 |
|---|---|---|
| `Enum.flat_map(l, fn x -> [x,x*2,x*3] end)` (3M) | 47,292 us | 48,504 us |
| `for ... do: [x,x*2,x*3]` (per-elem list, len 1M) | 38,984 us | 43,064 us |
| `List.flatten(for ... do: [..])` (3M) | 68,562 us | 64,183 us |

Elixir 1.20 neither exposes EEP-78 syntax nor lowers `Enum.flat_map`/`for` to
the new form; both versions are within noise of each other. The optimization is
Erlang-syntax-only.

## Verdict

**CONFIRMED** for Erlang/OTP 29.1.2 (compiles; single-pass codegen witnessed in
beam_disasm; 48.965 ms vs flatmap 50.142 ms vs append-shape 95.639 ms on 1M x 3).
**UNAVAILABLE** on OTP 28.x (parse error) and **REFUTED for Elixir 1.20** (no
syntax surface, no codegen lift; `Enum.flat_map` is version-parity with 1.19).

**Standing:** ALIVE (Erlang 29-only surface, both-toolchain tables above).

## Replay

```bash
# availability (EEP-78 mention)
grep -rn "EEP 78" ~/.asdf/installs/erlang/29.1.2/lib/syntax_tools-4.1.1/src/erl_syntax.erl
# compile probe (sources at /tmp/eep78_probe.erl, eep78_bench2.erl, eep78_comp29.erl)
ASDF_ERLANG_VERSION=29.1.2 asdf exec erlc /tmp/eep78_probe.erl   # exit 0
ASDF_ERLANG_VERSION=28.5.0.2 asdf exec erlc /tmp/eep78_probe.erl # exit 1 syntax error
ASDF_ERLANG_VERSION=29.1.2 asdf exec erl -noshell -eval 'eep78_bench2:main().'
ASDF_ERLANG_VERSION=29.1.2 asdf exec erl -noshell -eval 'L = lists:seq(1,1000000), eep78_comp29:run(L).'
ASDF_ELIXIR_VERSION=1.20.4-otp-29 asdf exec elixir /tmp/ex_eep78.exs
```
