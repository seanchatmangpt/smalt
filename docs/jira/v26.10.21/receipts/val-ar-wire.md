# VAL-WIRE — AR-WIRE-01/02/03 validation receipt

Context: solo

**Standing:** **PARTIAL_ALIVE** — AR-WIRE-01 ALIVE on host OTP 28 (native `json` present, SAX streaming real, Jason parity); AR-WIRE-02 PARTIAL_ALIVE (ALIVE on OTP 29.x, UNSUPPORTED on host 28); AR-WIRE-03 REFUTED as stated (strict generators `<-:-` do not compile on any pinned toolchain; "compr_assign" is not a feature — the idiom already compiles on 28).
Context: solo
Machine (`just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Toolchains

- Host: OTP **28.3.1** (erts 16.2, stdlib 7.2, compiler 9.0.4), `~/.erlmcp/otp-28.3.1/bin`
- OTP **29.0.6** (popcorn pin) and **29.1.1**, `~/.asdf/installs/erlang/*/bin`
- Probes (all landed in `/Users/sac/smalt/tmp/otp29_probes/`):
  - `p9_wire.escript` — native json vs chunked SAX streaming vs Jason, guard/strict/compr compile legs
  - `p10_wire_ca.erl` — `compile:file`-based guard/strict/compr court (authoritative for AR-WIRE-02/03)
  - `p13_wire_peak.exs` — peak-memory sampler bench incl. Jason under the Elixir runtime

## AR-WIRE-01 — native json / JSON engine: ALIVE on host

Availability: `code:which(json)` → `.../stdlib-7.2/ebin/json.beam` on 28.3.1 (OTP 27+ module, present on the host). Present on 29.0.6 and 29.1.1 as well.

Gate: **51.6 MB JSON** (300k documents in a top-level array), three decode paths:

| path | OTP | wall ms | retained after GC | peak (processes delta) |
|---|---|---|---|---|
| `json:decode/1` full term tree | 28.3.1 | 1393–1805 (3 runs) | ~0 KB | ~845 MB |
| `json:decode/1` | 29.1.1 | 1390 | ~0 KB | — |
| `json:decode/1` | 29.0.6 | 1418 | ~0 KB | — |
| SAX chunked streaming (64 KiB chunks, counting decoders) | 28.3.1 | 464–506 | **0 KB** | ~384 MB |
| SAX chunked streaming | 29.1.1 | 390 | **0 KB** | — |
| SAX chunked streaming | 29.0.6 | 390–435 | **0 KB** | ~384 MB |
| Jason `decode/1` (host 28, Elixir 1.19.5 runtime) | 28.3.1 | 1398–1818 | ~0 KB | ~867 MB |

- Big-document parity vs Jason: **true** (identical decoded terms, 46.9–51.6 MB docs).
- Jason beams built under smalt `_build/dev` load on OTP 28 only (toolchain-locked, not a capability gap).

Measured conclusions:

1. Native `json` is present and correct on the host (big-doc parity = true).
2. The SAX/continuation API (`json:decode_start/3` + `decode_continue/2`) works over
   chunked input with custom decoders: 300k items, 64 KiB chunks, counting decoders →
   **~3.3x throughput and zero term tree retained** vs full-tree `json:decode/1`.
3. The tree-avoidance win holds **only with custom discarding decoders**; default
   decoders build the tree either way.
4. Typed caveat: with chunked `decode_continue`, the continuation state keeps references
   into the input binary — SAX peak (~384 MB) is roughly half the full-tree peak (~845 MB),
   not near-input. The ARD's "Zero-Copy" title is **overclaimed**: streaming tree-avoidance
   is real, zero-copy was not achieved with the chunked feeding pattern measured here.
   Re-measurable with socket-fed chunks.

## AR-WIRE-02 — is_integer/3: PARTIAL_ALIVE

- Host 28.3.1: `compile:file` refuses `f(X) when is_integer(X, 0, 100) -> X.` →
  `gen_p9g.erl:1:41: illegal guard expression` (reproduced in p9 and p10).
- 29.0.6 and 29.1.1: guard compiles AND enforces the range —
  `GUARD3 ok50=50 bad200={error,function_clause} badatom={error,function_clause}`
  (positive + two negative legs). Matches `docs/jira/v26.10.20/receipts/otp29-capability-probes.md` claim 6.

Usable only under the OTP-29 toolchain as compile target; any `lib/` adoption must be
29-gated. Correctly typed **PARTIAL_ALIVE** (ALIVE on 29.x, UNSUPPORTED on host).

## AR-WIRE-03 — strict generators `<-:-` + compr_assign: REFUTED as stated

- Strict generators: `[X || X <-:- L]` → `syntax error before: ':'` on **28.3.1,
  29.0.6, AND 29.1.1**. The syntax does not exist on any pinned OTP. Items premised on it
  are premised on a nonexistent feature; re-scope to type-test filters
  (`X when is_integer(X)`) inside comprehensions, which compile everywhere.
- compr_assign: mid-comprehension assignment
  (`f(L) -> [begin Y = X + 1, Y * 2 end || X <- L].`) compiles and returns `[4,6,8]` on
  **all three** toolchains — plain Erlang, no OTP-29 feature exists to enable. The ARD's
  `compr_assign` terminology does not map to a real OTP capability.

## Verdict table

| # | ARD item | host 28.3.1 | 29.0.6 | 29.1.1 | Verdict |
|---|---|---|---|---|---|
| 1 | AR-WIRE-01 native json + SAX streaming | json present; SAX 464–506 ms / 0 retained | json present; SAX 390–435 ms | json present; SAX 390 ms / 0 retained | **ALIVE on host** (streaming ALIVE; "zero-copy" wording overclaimed) |
| 2 | AR-WIRE-02 is_integer/3 | compile-refused (`illegal guard expression`) | compiles, range-enforced | compiles, range-enforced | **PARTIAL_ALIVE** — ALIVE on 29.x, UNSUPPORTED on host |
| 3a | AR-WIRE-03 strict gen `<-:-` | syntax error | syntax error | syntax error | **REFUTED** on all toolchains |
| 3b | AR-WIRE-03 compr_assign | `[4,6,8]` plain Erlang | `[4,6,8]` | `[4,6,8]` | **REFUTED as a feature** — nothing to adopt |

## Falsifiers

- AR-WIRE-01 flips if `p9_wire.escript` prints `NATIVE_SAX` other than `ok count=...` or PARITY goes false.
- AR-WIRE-02 flips if a compiled `is_integer(X,0,100)` guard on 29.x accepts out-of-range input.
- AR-WIRE-03 flips when p10 prints a `STRICT_GEN good=...` success line on any pinned toolchain.

## Probe replay

```
PATH="$HOME/.erlmcp/otp-28.3.1/bin:$PATH" escript tmp/otp29_probes/p9_wire.escript
PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$PATH" escript tmp/otp29_probes/p9_wire.escript
# per toolchain: erlc tmp/otp29_probes/p10_wire_ca.erl && erl -noshell -pa <dir-with-beam> -eval 'p10_ca:run()'
elixir tmp/otp29_probes/p13_wire_peak.exs   # from /Users/sac/smalt (Jason ebin under _build/dev)
```

## Reproduction (2026-10-21 backfill, fresh run)

```text
$ cd /Users/sac/smalt/tmp/otp29_probes
$ PATH="$HOME/.erlmcp/otp-28.3.1/bin:$PATH" escript p9_wire.escript
PAYLOAD bytes=51623147
NATIVE_DECODE ms=1477 retained_delta_kb=0
NATIVE_SAX ok count=300000
NATIVE_SAX_BENCH ms=445 retained_delta_kb=0
exit 0
$ PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$PATH" escript p9_wire.escript
PAYLOAD bytes=51623147
NATIVE_DECODE ms=1493 retained_delta_kb=7
NATIVE_SAX ok count=300000
NATIVE_SAX_BENCH ms=404 retained_delta_kb=0
exit 0
```

Native `:json` + SAX continuation legs reproduce (51.6 MB payload, 300k docs,
zero retained after GC, ~3.3x SAX throughput). The Jason comparison leg requires
the smalt `_build/dev` Jason ebins via `-pa` (escript-only invocation crashes in
`Jason.decode/2`; toolchain-locked, as the receipt body records) — that leg's
output lives in the cited artifact.
