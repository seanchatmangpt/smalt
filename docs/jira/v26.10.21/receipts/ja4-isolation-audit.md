# JA-4: Isolation Audit (no shared mutable state / no NIF contamination) — RE-WITNESSED

Repo: `/Users/sac/smalt` · Branch: `main` · HEAD: `514431b` · Date: 2026-10-21 · Context: solo.

**Re-witness note**: original audit (READ-ONLY agent, parent-persisted digest, no embedded
**Standing:** PASS
output → SUSPECT flag) has been re-derived from the CURRENT tree with real commands. The two
violations flagged by the original audit were FIXED in-flight by the JA-R1/R2 lane
(commit `4cb91e1` "JA-R1/R2 in-flight snapshots"; no standalone JA-R2 receipt file minted at
re-witness time — the fix commit is cited as authority).

## Findings (re-derived, current tree)

### 1. `lib/smalt/apim.ex` — FIXED (was: dead `:rate_table_owner` key + heir-less lazy ETS)

Current state (read at HEAD `514431b`):

```
$ grep -n "rate_table_owner" lib/smalt/apim.ex
60:    Process.set_label(%{service: :apim, role: :rate_table_owner})
62:    :persistent_term.put({__MODULE__, :rate_table_owner}, self())
```

- The rate-table owner is now a proper proc_lib GenServer (`GenServer.start_link(__MODULE__,
  :ok, name: __MODULE__)`, line 55) — not a naked spawn. `init/1` sets the proc_lib label and
  publishes the owner pid under `{Smalt.Apim, :rate_table_owner}`.
- The key is **no longer dead**: it is read by
  `test/internal/impl6_process_label_test.exs:145`:

  ```
  $ grep -rn "rate_table_owner" lib/ test/ | grep -v apim.ex
  test/internal/impl6_process_label_test.exs:145:    owner = :persistent_term.get({Smalt.Apim, :rate_table_owner})
  test/internal/impl6_process_label_test.exs:148:    assert label == %{service: :apim, role: :rate_table_owner}
  ```

- The lazy ETS creation now carries `:write_concurrency` + `:read_concurrency` and a
  `{:heir, Process.whereis(:init), []}` (apim.ex:135-160), so creator death no longer deletes
  the window counters.

### 2. `lib/smalt/messaging/amqp/atom_bridge.ex` — FIXED (was: hot persistent_term writes at :127)

```
$ grep -n ":persistent_term\.\(put\|get\)" lib/smalt/messaging/amqp/atom_bridge.ex
$ echo exit=$?
exit=1
```

Zero `:persistent_term.put/get` calls remain in atom_bridge.ex (the single remaining
`persistent_term` string is a code comment). The window ledger is now the ETS table
`:smalt_amqp_atom_rl` — `:named_table, :set, :public, read+write_concurrency, heir to :init`
(atom_bridge.ex:126-163). Writes are `:ets.insert/2` on the existing error atom as key
(tuple-wrapped as `{reason, ts}`), no global scheduler sync per write.

### 3. `lib/smalt/json_compat.ex` — LAWFUL (unchanged)

Call-scoped process-dictionary use inside `stream/3`, nil-ed in `after` (json_compat.ex:129-143),
documented in-file: "Hooks and deliver/4 both execute in the caller process … so stream state
rides the process dictionary for the duration of the call." Not shared state. JA-8 concurs.

### 4. Zero-NIF on `lib/smalt/wasm/` — VERIFIED

```
$ grep -rn ":erlang.load_nif\|Code.load_file\|load_nif" lib/smalt/wasm/; echo "exit=$?"
grep-load_nif-wasm exit=1
```

Zero matches on the sandbox path. `lib/smalt/wasm/worker.ex:122` uses
`Port.open({:spawn_executable, program}, …)` — external OS process, no NIF object code in the
ERTS address space. Scoped claim as before: `lib/smalt/affidavit/wasm_engine.ex` uses Wasmex
(a NIF library) outside this path — disclosed in WASM-SANDBOX-SPEC §5.

## Embedded verification session

```
$ elixir --version
Erlang/OTP 28 [erts-16.2] [source] [64-bit] [smp:16:16] [ds:16:16:10] [async-threads:1] [jit]

Elixir 1.19.5 (compiled with Erlang/OTP 28)
```

(Toolchain differs from the popcorn pin — this is the ambient VM used only for static
re-derivation greps; no behavior claims ride on it.)

## Standing

**PASS (post-fix re-witness)**: both original violations closed by the JA-R1/R2 lane
(commit `4cb91e1`): apim.ex GenServer owner + live published key + concurrency/heir ETS;
atom_bridge.ex persistent_term ledger → concurrency ETS with heir. json_compat pdict
borderline-but-documented (LAWFUL). Zero-NIF VERIFIED on `lib/smalt/wasm/` (open_port only).
Violations: 0.
