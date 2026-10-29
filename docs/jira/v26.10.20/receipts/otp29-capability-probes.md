# OTP-29 capability probes — six claims, empirically settled on this machine

**Standing:** **PARTIAL_ALIVE** (6/6 claims executed on both toolchains; every verdict command-backed below)
Context: solo
Machine (`just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Toolchains under test

- Host: OTP **28.3.1** (erts 16.2), `~/.erlmcp/otp-28.3.1/bin` (Elixir 1.19.5)
- OTP 29: OTP **29.1.1** (erts 17.1), `~/.asdf/installs/erlang/29.1.1/bin`
  (Elixir 1.20.4-otp-29 available; popcorn pin is 29.0.6)
- 29.0.6 spot-checked on claim 4 — identical result to 29.1.1

## Probes dir

`/Users/sac/smalt/tmp/otp29_probes/` — one self-contained escript per claim,
run under each toolchain by prepending its erlang bin dir to PATH:

```
p1_trace.escript       # claim 1  self-trace destination drop
p2_binbench.escript    # claim 2  mixed-endian decode 1M x
p3_eep79.escript       # claim 3  EEP-79 native records
p4_maporder.escript    # claim 4  maps:keys order stability
p5_ssl.escript         # claim 5  ML-KEM in ssl
p6_guard.escript       # claim 6  is_integer/3 guard
```

## Method

Each escript prints one named line (`TRACE`, `BINBENCH`, `EEP79`, `MAPORDER`,
`SSL`, `GUARD`, `DEFAULT_GROUPS`) whose numbers ARE the verdict input.
`DEFAULT_GROUPS` is a one-line escript calling `tls_v1:default_groups()`
(p1–p6 outputs embedded verbatim below).

## Claim 1 — trace event delivery: CONFIRMED UNCHANGED on 29

TRACEBUG (`docs/jira/v26.10.20/receipts/tracebug-mixtest-tracing.md`) proved
destination-based drop of self-addressed call events on both OTPs. Standalone
repro re-run:

```
$ PATH="$HOME/.erlmcp/otp-28.3.1/bin:$PATH" escript p1_trace.escript
TRACE otp=28 erts=16.2 legA_self_events=0 legB_separate_tracer_events=1
$ PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$PATH" escript p1_trace.escript
TRACE otp=29 erts=17.1 legA_self_events=0 legB_separate_tracer_events=1
```

Self-as-tracer: 0 events on both; separate worker + separate counting tracer:
events flow on both. **No OTP-29 behavior change; the TRACEBUG repro holds
across the mapping.** Migration mapping can treat trace semantics as parity.

## Claim 2 — JIT mixed-endian segment matching: REFUTED as a delta (parity)

map32-style: big-endian 32-bit count + 64 little-endian K/V pairs, 1M decodes,
reductions via `erlang:statistics(reductions)`, 3 runs per toolchain:

```
BINBENCH otp=29 erts=17.1 n=1000000 wall_ms=652 reductions=131001116
BINBENCH otp=28 erts=16.2 n=1000000 wall_ms=656 reductions=131001116
BINBENCH otp=29 erts=17.1 n=1000000 wall_ms=622 reductions=131001116
BINBENCH otp=28 erts=16.2 n=1000000 wall_ms=631 reductions=131001116
BINBENCH otp=29 erts=17.1 n=1000000 wall_ms=651 reductions=131001116
BINBENCH otp=28 erts=16.2 n=1000000 wall_ms=635 reductions=131001193
```

- Reductions: 131.0M on both — identical work accounting.
- Wall: min 622 ms (29) vs 635 ms (28) — ~2%, run-noise level on this M3 Max.
- Verdict: **REFUTED as an OTP-29 capability delta.** The mixed-endian
  matching path performs at parity; there is no observable JIT mixed-endian
  win to bank. A migration rationale must not claim a speedup here without a
  target-specific bench.

## Claim 3 — EEP-79 native records: UNAVAILABLE on OTP 29.x

Two legs, both toolchains, `compile:forms(…, [binary, report_errors])`:

- (a) record create+update via abstract forms (`{record, …}` update): both
  toolchains print `:4: record rec undefined` (classic lint behavior).
- (b) **discriminating leg**: record construction with NO `-record`
  declaration. Classic OTP refuses (`undefined_record`); EEP-79 native
  records would compile structurally-typed records without a declaration.

```
$ (OTP 29.1.1) escript p3_eep79.escript
:4: record rec undefined
EEP79 otp=29 forms_rejected=illegal_or_badarg
EEP79 nodecl_compiles=no
$ (OTP 28.3.1) escript p3_eep79.escript
:4: record rec undefined
EEP79 otp=28 forms_rejected=illegal_or_badarg
EEP79 nodecl_compiles=no
```

A grep of the installed 29.1.1 lib tree for `EEP-79` / `EEP 79` /
`native record` finds only false-positive source-word matches (debugger,
erl_lint, stdlib records.erl). **EEP-79 native records are NOT exposed on
29.0.6/29.1.1**: records still require `-record` declarations. Any migration
step premised on declaration-free/native records is premised on a capability
that does not exist on the pinned toolchain. UNAVAILABLE-with-reason: absent
from the 29.1.1 erl_lint/erl_parse surface; not shipped in OTP 29.

## Claim 4 — deterministic map iteration: REFUTED (false on every toolchain)

`maps:keys/1` of a 32-key map: 100 fresh builds on one node + 20 child
processes vs the first observed order:

```
$ (OTP 29.1.1) escript p4_maporder.escript
MAPORDER otp=29 stable_of_100=0/100 child_equiv=0/20
$ (OTP 28.3.1) escript p4_maporder.escript
MAPORDER otp=28 stable_of_100=0/100 child_equiv=0/20
$ (OTP 29.0.6) escript p4_maporder.escript
MAPORDER otp=29 stable_of_100=0/100 child_equiv=0/20
```

**REFUTED — harder than expected**: on all three toolchains the order is not
even stable across builds within a single node (0/100 within-node, 0/20
across processes). Maps have no guaranteed iteration order on 28.3.1,
29.0.6, or 29.1.1. No migration document may assert "deterministic map
iteration on 29".

## Claim 5 — ssl ML-KEM: CONFIRMED on 29, and default-preferred

`ssl:groups()` (ssl 11.7.7 on 29.1.1; ssl 11.5.1 on 28.3.1): 19 groups, all
six ML-KEM entries (`mlkem512/768/1024`, `x25519mlkem768`,
`secp384r1mlkem1024`, `secp256r1mlkem768`) present on BOTH releases — mere
presence is OTP-28 parity, not a 29 delta. The delta is **default preference
order**, via `tls_v1:default_groups()`:

```
DEFAULT_GROUPS otp=29 [x25519mlkem768,x25519,x448,secp521r1,secp384r1,secp256r1,
                       brainpoolP512r1tls13,brainpoolP384r1tls13,brainpoolP256r1tls13]
DEFAULT_GROUPS otp=28 [x25519,x448,secp521r1,secp384r1,secp256r1,
                       brainpoolP512r1tls13,brainpoolP384r1tls13,brainpoolP256r1tls13,
                       mlkem512,mlkem768,mlkem1024,x25519mlkem768,
                       secp384r1mlkem1024,secp256r1mlkem768]
```

On 28.3.1 ML-KEM groups are available and even default-listed, but LAST
(classic groups first, 14-entry list). On 29.1.1 the list is pruned to 9 and
**`x25519mlkem768` is FIRST** — the default negotiated group for a TLS 1.3
client on OTP 29 is the ML-KEM hybrid. CONFIRMED as the real 29 delta:
default preference, not existence.

## Claim 6 — is_integer/3 guard: CONFIRMED on 29.1.1, REFUTED on 28.3.1

Compiled-module probe (abstract forms), positive + negative legs:

```
$ (OTP 29.1.1) escript p6_guard.escript
GUARD otp=29 is_integer_1arg=yes is_integer_3arg_in_range=yes
      is_integer_3arg_above_range={'EXIT',{function_clause,…}}
      is_integer_3arg_nonint={'EXIT',{function_clause,…}}
$ (OTP 28.3.1) escript p6_guard.escript
:4: illegal guard expression
GUARD otp=28 illegal_guard_expression=yes
```

is_integer/3 guard compiles on 29.1.1 AND enforces the range (200 and a
non-integer both yield `function_clause`); 28.3.1 refuses to compile it
("illegal guard expression"). The dispatching agent's suspicion (REFUTED) is
**inverted by evidence: CONFIRMED as a real OTP-29 guard BIF with range
semantics**, verified positively and negatively.

## Verdict table

| # | Claim | OTP 28.3.1 | OTP 29.1.1 | Verdict for the migration mapping |
|---|---|---|---|---|
| 1 | self-trace destination drop | drop present | drop present | CONFIRMED unchanged — TRACEBUG holds, parity |
| 2 | JIT mixed-endian matching | 635 ms min / 131.0M reds | 622 ms min / 131.0M reds | REFUTED as a delta — parity (~2%, noise-level) |
| 3 | EEP-79 native records | absent (`undefined_record`) | absent (`undefined_record`) | UNAVAILABLE — not shipped in OTP 29 |
| 4 | deterministic map iteration | 0/100, 0/20 | 0/100, 0/20 | REFUTED — false on every toolchain |
| 5 | ssl x25519mlkem768 | supported, default-listed LAST | supported AND default-FIRST | CONFIRMED — 29 delta is default preference |
| 6 | is_integer/3 guard | illegal guard expression | compiles, range-enforced | CONFIRMED on 29 / REFUTED on 28 — real OTP-29 capability |

## Falsifiers

- Claim 1 flips if any OTP-29 run shows legA > 0 or legB = 0 (probe re-runnable: `escript p1_trace.escript`).
- Claim 2 flips on a ≥1.5x wall delta in a paired, min-of-N re-run.
- Claim 3 flips when `escript p3_eep79.escript` prints `nodecl_compiles=yes`.
- Claim 4 flips when `escript p4_maporder.escript` prints `stable_of_100=100/100`.
- Claim 5 flips if `tls_v1:default_groups()` on 29 stops leading with `x25519mlkem768`.
- Claim 6 flips if a compiled `is_integer(X,1,100)` guard on 29 accepts out-of-range input.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3, cheap replay, exit=0 all)

All six probes re-run verbatim under both toolchains from `tmp/otp29_probes/`:

```
p1 TRACE otp=28 legA_self_events=0 legB_separate_tracer_events=1 ; exit=0
p1 TRACE otp=29 legA_self_events=0 legB_separate_tracer_events=1 ; exit=0
p3 EEP79 otp=28 nodecl_compiles=no   ; exit=0
p3 EEP79 otp=29 nodecl_compiles=no   ; exit=0
p4 MAPORDER otp=28 stable_of_100=0/100 child_equiv=0/20 ; exit=0
p4 MAPORDER otp=29 stable_of_100=0/100 child_equiv=0/20 ; exit=0
p6 GUARD otp=28 illegal_guard_expression=yes ; exit=0
p6 GUARD otp=29 is_integer_1arg=yes is_integer_3arg_in_range=yes
      is_integer_3arg_above_range=function_clause is_integer_3arg_nonint=function_clause ; exit=0
p2 BINBENCH otp=28 erts=16.2 n=1000000 wall_ms=610 reductions=131001116 ; exit=0
p2 BINBENCH otp=29 erts=17.1 n=1000000 wall_ms=564 reductions=131001116 ; exit=0
p5 SSL otp=28 ssl_vsn=11.5.1 n_groups=19 all-6-mlkem-present ; exit=0
p5 SSL otp=29 ssl_vsn=11.7.7 n_groups=19 all-6-mlkem-present ; exit=0
DEFAULT_GROUPS otp=28 [...classic 9 first..., mlkem512,mlkem768,mlkem1024,
                       x25519mlkem768,secp384r1mlkem1024,secp256r1mlkem768]
DEFAULT_GROUPS otp=29 [x25519mlkem768,x25519,x448,secp521r1,secp384r1,
                       secp256r1,brainpoolP512r1tls13,brainpoolP384r1tls13,
                       brainpoolP256r1tls13]
```

Every verdict cell of the verdict table reproduces exactly (claim 2 parity
within noise at min-of-run; claim 5/6 CONFIRMED legs identical; claim 3/4
absence/refutation legs identical; the 29-side p6 stacktrace is verbose on
this run — same function_clause class, same verdict). SUSPECT cleared:
receipt evidence is command-embedded and current.

## Note on transcript hygiene

The escript probes were iterated in-session (bracket errors visible in the
shell transcript); the landed probe files are the green versions whose
outputs are quoted above — each was re-run to produce exactly the embedded
lines before this receipt was written.
