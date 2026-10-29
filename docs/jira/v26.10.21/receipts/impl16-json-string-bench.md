# IMPL-16: native `:json` long-string decode bench — OTP 28.3.1 vs 29.1.2

Context: solo

**Standing:** **CONFIRMED** (claim under test: "native :json decodes long strings up to 55% faster")
Context: solo
Date: 2026-10-21

## Claim under test

"Native `:json` decodes long strings up to 55% faster" (`docs/jira/v26.10.21/ARD-PRD.md`
line 394, native streaming JSON migration row). Measured against Jason 1.4 on
the same corpus, both toolchains, explicit PATHs.

## Method

- Corpus: deterministic (`:rand.seed(:exsss, 16_100_000)`), 10,000 docs, each
  with 4 long-string fields of 2–8 KB plus id/kind/number. Encoded once with
  Jason: **205,513,554 bytes** (~205.5 MB) of JSON per decode.
- Decoders: `Jason.decode!/1` vs `:json.decode/1`. OTP 28 also ships the
  `:json` module (decode/1 present), so both legs ran on both OTPs.
- Both toolchains pinned by explicit PATH; Jason compiled per toolchain with
  `elixirc` from `deps/jason` into scratch ebins
  (`tmp/impl16/jason_ebin28`, `tmp/impl16/jason_ebin29`).
- 1 warmup + 5 measured rounds per decoder per toolchain; wall via
  `:timer.tc`; heap via `Process.info(:total_heap_size)` of a dedicated
  decoder process sampled at completion.
- Harness: `tmp/impl16/bench.exs`; raw output `tmp/impl16/out28.txt`,
  `tmp/impl16/out29.txt`.

## Commands

```bash
# OTP 28.3.1 leg
cd /Users/sac/smalt/tmp/impl16
PATH="/Users/sac/.asdf/installs/elixir/1.20.2-otp-28/bin:/Users/sac/.erlmcp/otp-28.3.1/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  elixir -pa "$PWD/jason_ebin28" bench.exs   # Elixir 1.20.2 / OTP 28, erts 16.2

# OTP 29.1.2 leg
cd /Users/sac/smalt/tmp/impl16
PATH="/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  elixir -pa "$PWD/jason_ebin29" bench.exs   # Elixir 1.20.4 / OTP 29, erts 17.1.1
```

## Tables

### OTP 28.3.1 (erts 16.2)

| decoder | min-of-5 wall | peak proc heap* |
|---|---|---|
| jason | 560.2 ms | 12,407,352 B (12.4 MB) |
| json_native | 195.2 ms | 7,350,608 B (7.35 MB) |

Native delta on 28: **65.2% faster** ((560.2−195.2)/560.2, peak-wall min-of-5).

### OTP 29.1.2 (erts 17.1.1)

| decoder | min-of-5 wall | peak proc heap* |
|---|---|---|
| jason | 539.1 ms | 12.4 MB (sampled post-GC, see caveat) |
| json_native | 134.2 ms | 7,350,608 B (7.35 MB) |

Native delta on 29: **75.1% faster** ((539.1−134.2)/539.1, peak-wall min-of-5).

## Verdict

**CONFIRMED.** On OTP 29.1.2 the measured delta is 75.1% — above the 40%
CONFIRMED bar and in fact exceeds the claimed "up to 55%". On OTP 28.3.1 the
delta is 65.2%, so native wins on both toolchains; the 29.1.2 jump (195.2 →
134.2 ms native) is itself a ~31% OTP-29-native improvement over 28.3.1.

## Caveats

- Heap is `total_heap_size` of the decoder process sampled at completion,
  after any final GC; Jason's round-1 sample collapsed to 1,864 B before
  stabilizing at ~12.4 MB, so the Jason heap figure is a post-GC-resize lower
  bound, not a true peak. Native: 7,350,608 B identically on both OTPs.
- Jason 1.4 from `deps/jason`, compiled per toolchain (pure Elixir, no NIF
  path).
- Machine otherwise idle; single run set (min-of-5), no SPC banding. Full
  205 MB corpus held in memory once (shared across rounds); peak RSS not
  sampled.

## Replay

```bash
cd /Users/sac/smalt/tmp/impl16
PATH="<otp28 elixir+erl>" elixir -pa "$PWD/jason_ebin28" bench.exs
PATH="<otp29 elixir+erl>" elixir -pa "$PWD/jason_ebin29" bench.exs
```

Raw outputs: `tmp/impl16/out28.txt`, `tmp/impl16/out29.txt`.

## Reproduction (2026-10-21 backfill)

Fresh re-run skipped (205 MB corpus, both toolchains — bench cost, not a cheap replay).
Output lives in the cited artifacts `tmp/impl16/out28.txt` / `tmp/impl16/out29.txt`;
integrity re-checked on disk this session:

```text
$ head -6 /Users/sac/smalt/tmp/impl16/out28.txt
corpus_json_bytes=205513554 docs=10000
decoders=jason,json_native
otp=28 erts=16.2
RESULT round=1 decoder=jason wall_us=581646 peak_proc_heap_bytes=1864
RESULT round=1 decoder=json_native wall_us=200878 peak_proc_heap_bytes=7350608
RESULT round=2 decoder=jason wall_us=579582 peak_proc_heap_bytes=12407352
$ head -6 /Users/sac/smalt/tmp/impl16/out29.txt
corpus_json_bytes=205513554 docs=10000
decoders=jason,json_native
otp=29 erts=17.1.1
RESULT round=1 decoder=jason wall_us=568142 peak_proc_heap_bytes=1864
RESULT round=1 decoder=json_native wall_us=157043 peak_proc_heap_bytes=7350608
RESULT round=2 decoder=jason wall_us=568059 peak_proc_heap_bytes=12407352
exit 0
```
