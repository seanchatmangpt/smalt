# VAL-OBS — AR-OBS-01..04 validation (validator, v26.10.21)

**Standing:** **PARTIAL_ALIVE** (4/4 cells adjudicated: 0 ALIVE, 1 PASS, 1 PARTIAL, 2 UNSUPPORTED — every verdict command-backed below)
Context: solo
Machine (`just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Toolchains under test

- Host/mix: OTP **28.3.1** (erts 16.2), `~/.erlmcp/otp-28.3.1/bin`
- OTP 29: **29.1.1** (erts 17.1), `~/.asdf/installs/erlang/29.1.1/bin`
- Popcorn pin: **29.0.6** (erts 17.0.6), `~/.asdf/installs/erlang/29.0.6/bin`

Probes: `/Users/sac/smalt/tmp/val_ar_obs/` (`obs_probes.escript` availability;
`obs02_label_court.escript` micro-court; `obs03_tprof.exs` call_memory profile).

## Availability matrix (raw probe output)

```
== OTP 28.3.1 ==
AVAIL otp=28 erts=16.2
OBS01 session_create_exported=false   OBS01 session_create_error=error:badarg
OBS02 proc_lib_set_label_exported=true
OBS03 tprof_available=true
OBS04 peer_available=true
== OTP 29.1.1 ==   (identical booleans; otp=29 erts=17.1)
== OTP 29.0.6 ==   (identical booleans; otp=29 erts=17.0.6)
```

## AR-OBS-01 — trace:session_create/3 — UNSUPPORTED

`erlang:function_exported(trace, session_create, 3) == false` and a direct
call raises `badarg` on **all three toolchains, including OTP 29.1.1** — the
API does not exist yet, so the ARD-PRD Phase-4 claim ("courts must initialize
isolated trace sessions via trace:session_create/3") is re-scoped: typed
**UNSUPPORTED** and dropped from Phase 4 until it lands in a real OTP release.

TRACEBUG cross-note (`docs/jira/v26.10.20/receipts/tracebug-mixtest-tracing.md`,
re-confirmed by probe p1 in `otp29-capability-probes.md`): the "inert tracing
under mix test" root cause is a **destination-based drop of self-addressed
call events on ALL versions** (legA_self_events=0 on both OTP 28 and 29;
separate-tracer legs flow on both). Session-based isolation would not have
fixed that drop even if the API existed — both halves of the claim fail
independently.

## AR-OBS-02 — proc_lib:set_label crash-report rendering — PASS

Micro-court (`obs02_label_court.escript`, all three toolchains): spawn a
`proc_lib` process, `set_label({val_obs, probe_label_42})`, crash it
(`exit(bang)`), capture the crash report via the default logger handler.

Verbatim stdout on each OTP:

```
=CRASH REPORT====
  crasher:
    initial call: ...'-main/1-fun-0-'/0
    pid: <0.87.0>
    process_label: {val_obs,probe_label_42}
    exception exit: bang
```

`label_rendered=1` / `exit=0` on 28.3.1, 29.1.1, and 29.0.6. The label
renders as `process_label:` in the crash report across the whole toolchain
matrix. PASS: test-court inspectors may label processes and assert on
`process_label` in crash reports (portable 28→29, popcorn-pin included).

## AR-OBS-03 — tprof call_memory — PARTIAL_ALIVE (tool available, CI fence not built)

`tprof` module present on all three toolchains (ships in `tools-4.1.3`). Live
court under host mix (MIX_ENV=test, ephemeral-port-free — boots only
`Smalt.Store` + cosmos engine, no fixed ports, substrate untouched):
`tmp/val_ar_obs/obs03_tprof.exs`, one real cosmos put_item (POST create then
profiled PUT replace, `PREPUT {:ok, 200, ...}` confirms the 200 path):

```
PREPUT {:ok, 200, %{"etag" => "\"08bf1a10-b488-40f4-8d05-1c99a3375fd6\"", ...}, ...}
OBS03 {"otp":"28","rows":51,"alloc_words":134,"top":[{"mfa":"{String, :replace_leading, 6}","alloc_words":22},{"mfa":"{Jason.Decoder, :string, 6}","alloc_words":3},{"mfa":"{Jason.Decoder, :array, 6}","alloc_words":2},{"mfa":"{Jason.Encode, :escape_json_chunk, 5}","alloc_words":32},{"mfa":"{Jason.Decoder, :value, 5}","alloc_words":9}]}

**Measurement: ~134 allocated words per cosmos put_item (engine path,
288-byte payload doc), measured via `tprof:profile(fun, #{type => call_memory,
report => return})` on OTP 28.** Note: engine path only
(`Smalt.DataPlane.Cosmos.put_doc/5` against live `Smalt.Store` ETS tables) —
the HTTP plug pipeline (Jason encode/decode of the request/response) is
excluded; `Jason.Encode.escape_json_chunk` rows in the top-5 are the doc-body
encode inside the engine. CI memory ceiling fence (ARD-PRD Phase 4: "Enforce
memory allocation ceilings in CI using tprof with #{type => call_memory}") is
**not built** — that is the missing half; cell stands at PARTIAL_ALIVE until
the fence lands. API notes captured for the fence author: `tprof:profile/2`
returns `{:ok, {call_memory, [{M, F, A, [{pid, count, words}]}]}}` (third
element is TOTAL words, not per-call), `report => return` suppresses printing,
and under `mix run` the tprof ebin must be added manually
(`code.root_dir()/lib/tools-*/ebin` is not on the mix code path).

## AR-OBS-04 — peer module — PARTIAL (available, no multi-node court)

`code:which(peer) != non_existing` on all three toolchains (peer shipped in
OTP 25, so availability was expected and is confirmed empirically). The repo
has **no multi-node testbed** — no distributed court exercises
`peer:start/2`-based remote spawn anywhere under test/, and the POWL 2.0
charter does not scope one. Falsifier for the missing court: a two-node
`peer:start(#{}#{...})` round-trip that spawns a process on the remote node
and asserts the remote pid answers a `:gen_server.call` — until such a court
exists in-repo, this cell cannot rise above PARTIAL.