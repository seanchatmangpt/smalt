# VAL Receipt — AR-DATA-01..04 Probe Validation (Phase-2 ETS claims)

**Standing: PARTIAL** — every API named in the ARD Phase-2 data-plane pillar exists on the
pinned toolchains (nothing to type UNSUPPORTED at the availability layer), but two
ARD-claimed semantics are materially wrong (AR-DATA-02 name/signature, AR-DATA-04 grow
semantics) and adoption counts remain 0 (per `phase2-ets-audit.md`). Each claim must be
re-scoped per the verdict table before any `lib/` migration.

Date: 2026-10-21. Repo: /Users/sac/smalt. Lane: VAL-DATA (validator; `lib/` untouched).
Input claim register: `docs/jira/v26.10.21/receipts/phase2-ets-audit.md`.
Context: solo.

## 0. Toolchains under probe

| toolchain | source | OTP / ERTS | Elixir |
|---|---|---|---|
| T1 (homebrew) | /opt/homebrew/bin/elixir | OTP 28 / ERTS 16.2 | 1.19.5 |
| T2 (local build) | /Users/sac/otp_src_28.3.1/bin/erl | OTP 28 / ERTS 16.2 | (none attached; Erlang-level probes only) |

Probes (scratch, not part of the lane's deliverable tree): `tmp/val-ar-data/ar_data_probe.erl`
(erlc'd, run under both toolchains), `tmp/val-ar-data/elx_probe.exs`,
`tmp/val-ar-data/resize_probe.exs` (T1 only — Elixir-level).

## 1. Verdict table

| # | Claim | T1 (OTP 28 / Elixir 1.19.5) | T2 (OTP 28.3.1) | Verdict | Correction for re-scope |
|---|---|---|---|---|---|
| AR-DATA-01 | `{write_concurrency, :auto}` valid on pinned OTP | AVAILABLE | AVAILABLE | **AVAILABLE** — unblocked at the API layer; the audit's gap is adoption only (0/55 `:ets.new` sites; 16 boolean `true`) | mechanical re-flag may proceed |
| AR-DATA-01b | `{decentralized_counters, true}` alongside `:auto` | AVAILABLE | AVAILABLE | **AVAILABLE** — option accepted, `update_counter` correct on a WC-`:auto` table | may pair with C1 re-flag |
| AR-DATA-02 | `ets:next_lookup` traversal | AVAILABLE | AVAILABLE | **AVAILABLE with corrections** — export is `next_lookup/2` (Table, Key1), not the audit's `next_lookup/1`; **badarg on `set` tables** (ordered_set-only, §2.2 last row); past-end returns the bare atom `:'$end_of_table'`, not a `{Key, Object}` tuple | traversal loops must match the atom; set-table callers (most of smalt's counter tables) cannot use it at all |
| AR-DATA-02b | `ets:update_element/4` | AVAILABLE | AVAILABLE | **AVAILABLE with signature correction** — /4 is `(Tab, Key, ElementSpec, DefaultTuple)` where ElementSpec = `{Pos, Value}` or `[{Pos, Value}]`, and DefaultTuple is inserted (with ElementSpec applied) when the key is absent. The `(Tab, Key, Pos, NewValue)` shape is **badarg** — it does not exist | true insert-or-update atomic; qualifies for the audit's "single atomic cycle" intent |
| AR-DATA-03 | Elixir `Registry.lock/3` on composite keys | AVAILABLE | n/a (no Elixir on T2) | **AVAILABLE** — ran a real lock on composite key `{:lock, "blob", "container/x"}` and got the fun's result back | availability ≠ suitability: phase2-ets-audit C3 documents the Store funnel as load-bearing (`next_seq` race history). API present does not justify the swap |
| AR-DATA-04 | `PartitionSupervisor.resize!/2` governs worker pools | AVAILABLE (exported) | n/a | **PARTIAL** — exists and functions, but two ARD-contradicting semantics: (a) **cannot grow past the configured `partitions:` count**; only shrink/regrow within `[0, configured]`. (b) returns the **previous** count (4→2 returned `4`; 2→4 returned `2`), not `:ok` — callers expecting `:ok` MatchError | worker pools sized by resize! must boot at the max partition count and shrink; do not model elasticity as grow-past-config |

## 2. Embedded probe outputs

### 2.1 Erlang probes — byte-identical on T1 and T2 (both "OTP 28 / ERTS 16.2")

```
== ets {write_concurrency, auto} => AVAILABLE
   compiles, insert+lookup ok

== ets {decentralized_counters, true} + auto => AVAILABLE
   option accepted, update_counter ok

== ets:next_lookup/2 (ordered_set; chain + $end_of_table) => AVAILABLE
   first=1 second=2 past-end='$end_of_table'

== ets:update_element/3 ({Pos,Value}) => AVAILABLE
   update-in-place ok

== ets:update_element/4 (ElementSpec, DefaultTuple) insert-or-update => AVAILABLE
   update=true, default-insert=true (default tuple gets ElementSpec applied: {ghost,9,q})

== next_lookup/2 on SET table (expect badarg) => AVAILABLE
   badarg as documented (ordered_set-only)
```

### 2.2 `update_element/4` spec as exported (beam_lib dump, T1)

```
-spec update_element(Table, Key, ElementSpec, Default) -> boolean()
                        when
                            Table :: table(),
                            Key :: term(),
                            ElementSpec :: {Pos, Value} | [{Pos, Value}],
                            Pos :: pos_integer(),
                            Value :: term(),
                            Default :: tuple().
```

(The `(Tab, Key, Pos, NewValue)` call shape raises `error:badarg` with
`erl_stdlib_errors` cause `id` — recorded live during probing.)

### 2.3 Elixir probes (T1, Elixir 1.19.5 / OTP 28)

```
== Registry.lock/3 (composite key, exclusive) => available
   lock/3 ran, returned fun result; key {:lock, "blob", "container/x"} accepted

== PartitionSupervisor module availability => available
   module loaded, Code.ensure_loaded: {:module, PartitionSupervisor}
```

### 2.4 PartitionSupervisor.resize!/2 observation run

```
Elixir 1.19.5 / OTP 28
before: 4 live partitions
resize!(…,2) => 4; after: 2 live partitions
resize!(…,4) => 2; after: 4 live partitions
resize!(…,8) => "REFUSED: the number of partitions to resize to must be a number between 0 and 4, got: 8"
```

(Child census via `Supervisor.which_children/1` filtered to live pids; removed partitions
report `:undefined` pids after shrink. A negative result is recorded alongside the
positive: resize past config raises with the bound message — the gate is real, not silent.)

## 3. Falsifiers

- The verdicts are about AVAILABILITY on the two probed toolchains only; they do not
  certify contention performance of `{write_concurrency, :auto}` at smalt's table
  shapes (ARD perf gate line 96 remains untested).
- T2 carries no Elixir, so AR-DATA-03/04 (Elixir-level) were probed on T1 only. If the
  substrate migrates to a different Elixir release, re-probe before relying on
  `Registry.lock/3` / `resize!/2` (both landed in Elixir 1.19).

## 4. Standing & next actions

- **Standing: PARTIAL.** All six probed APIs are real on the pinned toolchains; two claim
  corrections must be propagated (AR-DATA-02 name/signature, AR-DATA-04 semantics) and the
  C3 suitability caveat holds.
- Propagate corrections into the ARD-PRD Phase-2 text before implementation lanes start.
- No `lib/` changes were made; scratch probes live in `tmp/val-ar-data/`.
