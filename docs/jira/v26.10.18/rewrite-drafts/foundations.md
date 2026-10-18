# Draft: test foundations — test_helper post-rewrite + test/support consolidation

Status: DRAFT (frozen tree; no edits, no git). Window: v26.10.18.
Date: 2026-10-18. Repo: /Users/sac/smalt.

Cross-references (do not duplicate): `assert-eventually.ex.md` (canonical
AssertEventually module of record, already smoke-verified),
`store-lro-wasm.md` §2/§3 (sweeper ownership + corpus poll migration),
`corpus-compliance.md` (corpus/compliance scaffolding consolidation),
`fence10-ratio.md`, `budget-gate.md` (:stress tier consumer),
`NO-SLEEP-DOCTRINE.md` (Law 1 consumer), `lib-sleeps.md` (lib-side, out of
scope here).

---

## 0. Ground truth the drafts must obey (measured on this tree, 2026-10-18)

1. **`test/support/` is not a compile path.** `mix.exs` defines no
   `elixirc_paths` (verified: zero matches in mix.exs), and
   `test/test_helper.exs` does not `Code.require_file` anything from
   `test/support/`. Today the only `SmaltTest.*` helper (`Lifecycle`) is
   defined inline in test_helper.exs, and `Smalt.Corpus.Helper` lives in
   `test/corpus/helper.exs`, require-filed only by `corpus_test.exs` (and
   mirrored by `compliance_test.exs` for the c1–c7 files) — which is why
   `Smalt.Corpus.Helper.resilient_clear` is unreachable from
   `egress_dispatch_test.exs` or `lro_test.exs` and each file grew a private
   copy. **Every helper below is dead on arrival unless P0 lands first.**
2. **No `:stress` tag exists yet** (zero `@tag :stress` matches under
   test/). The `exclude: [:stress]` line introduces the tag; it pairs with
   `budget-gate.md`'s tier table (`stress → 300_000 ms`) and the existing
   `test.amqp_wire` alias pattern (`mix.exs:42-43`).
3. **Env-mutation scale**: 65 test files call `Application.put_env(:smalt,
   ...)`; 48 read it back in restore paths. The leak-batch campaign
   (`docs/jira/v26.10.17/receipts/i21-leak-batch1.md` … `batch5`) patched
   these one file at a time with the tls_test-style save-prev + on_exit
   pattern and the egress/c3_cosmos-style `Process.put(:prev_*, …)`
   process-dictionary pattern — three drifted spellings of one law.

---

## 1. P0 — make `test/support/` a compile path (prerequisite for everything)

`mix.exs`:

```elixir
def project do
  [
    ...,
    elixirc_paths: elixirc_paths(Mix.env())
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

This is the standard Mix contract; it compiles `test/support/*.ex` into the
test build so every suite (including the runtime-`.exs`-required corpus and
compliance files) sees `SmaltTest.*`. `SmaltTest.Lifecycle` then moves out of
test_helper.exs into `test/support/lifecycle.ex` verbatim (it is already a
self-contained module; the move is mechanical, and test_helper keeps
requiring nothing — the beam is on the path).

---

## 2. `test/test_helper.exs` — post-rewrite configure (full draft)

```elixir
# Test isolation contract: docs/TEST_ISOLATION.md
#
# Default-excluded tags are NAMED, in-flight/known-gap exceptions (the
# original amqp_wire comment block is preserved verbatim — see current file
# lines 1-15; it stays).
ExUnit.configure(
  exclude: [
    :amqp_wire,
    :stress
  ]
)

# Degraded-host law (runs 21-30), preserved verbatim: SMALT_MAX_CASES caps
# ExUnit concurrency without touching any assertion. Unset = default.
max_cases = String.to_integer(System.get_env("SMALT_MAX_CASES") || "0")
if max_cases > 0, do: ExUnit.start(max_cases: max_cases), else: ExUnit.start()
```

Notes:
- **The Lifecycle module body moves out; nothing else does.** test_helper
  stays require-free for helpers: with P0 the helpers are compiled beams.
- **`:stress` exclusion law**: named-exclusion discipline unchanged (same
  header comment); re-enable with `mix test --include stress`. Introduced
  for the long-tier tests `budget-gate.md` tiers at 300 s; no test carries
  the tag on landing day (zero-impact introduction — the exclusion is
  vacuous until a suite adopts it, which is the point: the vocabulary
  exists before the pressure to misuse it does).
- **AssertEventually import**: test_helper cannot inject imports into test
  modules; the lawful carrier is a case template. Add
  `test/support/case.ex`:

```elixir
defmodule SmaltTest.Case do
  @moduledoc """
  Canonical base for new/migrated suites: ExUnit.Case with the shared
  helper imports. Migration is per-file and optional — `use ExUnit.Case`
  keeps working; this template exists so AssertEventually/Env/Store are
  one `use` away instead of a per-file import stanza.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import ExUnit.Callbacks
      import SmaltTest.AssertEventually
      import SmaltTest.Env
      import SmaltTest.Store
      import SmaltTest.Singleton, only: [start_supervised_singleton!: 2]
    end
  end
end
```

---

## 3. `test/support/` consolidation — one module per law

### 3.1 `SmaltTest.AssertEventually` — NO NEW DRAFT

Canonical source and smoke receipt:
`assert-eventually.ex.md` (module of record, lines 28-129, with its
2026-10-18 elixirc verification receipt). It lands verbatim at
`test/support/assert_eventually.ex`. **Precedence note**: `corpus-compliance.md`
proposes its own `assert_eventually!/3` + `quiescent_read` inside
Corpus.Helper; where they overlap, `assert-eventually.ex.md` wins (it has a
verification receipt; the other does not). `quiescent_read` (the shacl-fuzz
double-read law) is a genuine gap in the canonical module — draft it as a
thin function in `SmaltTest.Store` (§3.2), not a second retry engine.

### 3.2 `SmaltTest.Store` — canonical resilient store setup

Supersedes the *location* decision in `corpus-compliance.md` decision 1
(which places the canonical `resilient_clear` in `Smalt.Corpus.Helper`).
Rationale: Corpus.Helper is require-filed only by corpus_test/compliance_test,
so the 6 private copies in ordinary test files (egress_dispatch, lro, shacl
fuzz callers) can never adopt it; `test/support` is reachable from every
suite. Corpus.Helper becomes a delegating shim (its `arm/egress/json/code`
dispatch helpers stay put — they are Plug plumbing, not store law).

`test/support/store.ex`:

```elixir
defmodule SmaltTest.Store do
  @moduledoc """
  Canonical resilient shared-Store setup (v26.10.18). One implementation of
  the i21/i22 hardening: the window between `Lifecycle.ensure_store_up()`
  and `Store.clear/0` races an async sibling's shared-tree teardown; the
  named ETS tables die mid-clear (dead-table ArgumentError). Built ON
  AssertEventually so the tree has exactly one bounded-retry primitive.
  """
  import SmaltTest.AssertEventually, only: [eventually: 2]

  @dead_table_msg "table identifier does not refer to an existing ETS table"

  @doc "Clear the shared Store, retrying only the dead-table ArgumentError."
  @spec resilient_clear(keyword) :: :ok
  def resilient_clear(opts \\ []) do
    eventually(
      fn ->
        SmaltTest.Lifecycle.ensure_store_up()
        Smalt.Store.clear()
        case Keyword.get(opts, :post_seed) do
          nil -> {:ok, :cleared}
          seed -> seed.()
          # seed runs INSIDE the retry window — c1_arm's rescue-scope law
          {:ok, :seeded}
        end
      end,
      observable: "shared Store clear(+seed)",
      retry_on: {ArgumentError, @dead_table_msg}
    )
  end

  @doc """
  Canonical store setup for a suite: resilient_clear + optional seed.
  Replaces the bare `ensure_store_up(); Store.clear()` setups that produced
  FLAKE_LEDGER F2-F5/F10.
  """
  def resilient_setup(opts \\ []) do
    :ok = resilient_clear(opts)
    :ok
  end

  @doc """
  i22 double-read law (shacl_fuzz snapshot mechanism, generalized): retry
  until two consecutive reads agree — a torn read under concurrent mutation
  is discarded, only quiescent observations are returned. Bounded by
  AssertEventually's deadline; rescues the dead-table ArgumentError and
  GenServer exits via the same retry_on machinery (wrapped as ordinary
  retries inside `read_fun`).
  """
  def quiescent_read(read_fun, opts \\ []) do
    eventually(
      fn ->
        a = read_fun.()

        b = read_fun.()

        if a == b do
          {:ok, b}
        else
          {:retry, {:torn, a, b}}
        end
      end,
      Keyword.merge([observable: "quiescent read"], opts)
    )
  end
end
```

Consumers (per FLAKE_LEDGER): F2-F4 (shacl_fuzz setup, three faces), F5
(Corpus.Helper families), F10 (egress_dispatch setup). Corpus.Helper's
`resilient_clear/0` body becomes `SmaltTest.Store.resilient_clear()` and the
c1/c3/c4 private copies are deleted — the c3 divergence corpus-compliance.md
names (missing already_started wait) disappears because the canonical copy
rides `Lifecycle.ensure_store_up/0` (which HAS the child-aware wait).

### 3.3 `SmaltTest.Env` — canonical env save/restore

Collapses three drifted spellings of the same law: (a) leak-batch1-style
save-prev + `on_exit` restore with `:__unset__` sentinel (48 files),
(b) egress_dispatch `Process.put(:prev_*, …)` + `after` restore (the
"leak-batch process-dictionary pattern"), (c) c3_cosmos
`Process.put({__MODULE__, :prev_ru_limit}, …)` namespaced-pdict variant.
Each instance today re-implements: read prev → mutate → restore (put if
prev non-nil, delete if unset) — and each hand-rolled restore is a fresh
chance to restore a pre-existing non-nil value with `delete_env` (the exact
defect leak-batch1 finding 2 fixed in the identity tests).

`test/support/env.ex`:

```elixir
defmodule SmaltTest.Env do
  @moduledoc """
  Canonical Application-env save/restore (v26.10.18). Replaces the
  process-dictionary `:prev_*` pattern and the hand-rolled on_exit restores
  (leak-batch1..5 campaign). Restore discipline is load-bearing: put when
  the previous value was non-nil, delete_env when it was unset — never the
  reverse (leak-batch1 finding 2: `delete_env` on a pre-existing value
  destroys sibling-visible config).
  """

  @unset :__unset__

  @doc """
  Scoped mutation: saves prev, runs `fun`, restores in an `after` (exception-
  and flunk-safe). `kvs` is a keyword list of {key, new_value}.
  """
  @spec with(keyword, (-> term)) :: term
  def with(kvs, fun) when is_list(kvs) and is_function(fun, 0) do
    prev = Enum.map(kvs, fn {k, _} -> {k, Application.get_env(:smalt, k, @unset)} end)

    Enum.each(kvs, fn {k, v} -> Application.put_env(:smalt, k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn
        {k, @unset} -> Application.delete_env(:smalt, k)
        {k, v} -> Application.put_env(:smalt, k, e v)
      end)
    end
  end

  @doc """
  Setup-form: mutates env and registers the restore via on_exit. Use inside
  `setup` when the mutation must outlive setup (whole-test scoping).
  """
  @spec put_restored(keyword) :: :ok
  def put_restored(kvs) when is_list(kvs) do
    prev = Enum.map(kvs, fn {k, _} -> {k, Application.get_env(:smalt, k, @unset)} end)

    Enum.each(kvs, {k, v} -> Application.put_env(:smalt, k, v) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(prev, fn
        {k, @unset} -> Application.delete_env(:smalt, k)
        {k, v} -> Application.put_env(:smalt, k, v)
      end)
    end)

    :ok
  end
```

(Implementer corrections noted inline in review: stray `e` in the `with/2`
restore clause, and `Enum.each(kvs, {k, v} -> ...)` is missing its `fn`.
The CONTRACT is: prev read with `:__unset__` sentinel; try/after restore;
on_exit variant for setup-form.)

Call-site shape (replaces egress_dispatch_test.exs:291-313 and the c3
pdict variant):

```elixir
# was: prev = get_env; Process.put(:prev_skr_legacy, prev); put_env; after → pdict read + branch
result =
  SmaltTest.Env.with(skr_allow_legacy_header: false, fn ->
    call(:post, "/keys/legacy-key/release?api-version=7.4", ...)
    |> assert_legacy_refusal()
  end)
```

Scale note: 65 put_env files is the migration surface, but the LAW only
needs to land in the files with live leak risk (the ~15 the leak-batch
receipts touched plus any file both async and env-mutating). Migration is
per-file, mechanical, and never blocks the foundations landing.

### 3.4 `SmaltTest.Singleton` — named-singleton `start_supervised!` wrapper

For suites that need a NAMED GenServer instance the app supervisor also
owns (the collision class behind store-lro-wasm.md §2's sweeper faces:
global `Sweeper.sweep_now()` interference, F11-adjacent). The draft there
uses anonymous `start_supervised!({Sweeper, name: nil, tick_ms: :manual})`;
this wrapper covers the cases where a process MUST be name-addressable
(message-assertion targets, `:via` references from spawned tasks) without
colliding across async siblings or the app-owned singleton.

```elixir
defmodule SmaltTest.Singleton do
  @moduledoc """
  Start a child spec under the test supervisor under a UNIQUE per-test name
  (`{:via, Registry, {SmaltTest.SingletonRegistry, {module, ref}}}`), so
  async sibling suites can never collide on a registered name and the
  app-owned named singleton is never shadowed.
  """

  def start_supervised_singleton!(child_spec, opts \\ []) do
    {:ok, _} = Registry.start_link(keys: :unique, name: SmaltTest.Registry)
    {:ok, _} = Registry.start_link(keys: :duplicate, name: SmaltTest.RegistryDup)

    module = opts[:module] || elem(child_spec, 0)
    ref = make_ref()

    name = {:via, Registry, {SmaltTest.Registry, {module, ref}}}

    pid = start_supervised!(Supervisor.child_spec({module, Keyword.put(opts, :name, name)}, id: ref))

    {pid, name}
  end
end
 Registry.start_link should be guarded (`name: SmaltTest.Registry` already
started by a sibling → rescue/ignore :already_started, or start it once in
test_helper). Simpler lawful form: start both registries in test_helper
after ExUnit.start, once per run.
```

Contract notes (the load-bearing parts):
- `start_supervised!/1` (ExUnit.Callbacks) remains the lifetime owner — the
  wrapper only derives the unique name; a crash fails the owning test with
  the child's exit reason, cleanup is supervisor-ordered before on_exit.
- `Registry.start_link` is run-scoped: start ONCE in test_helper (after
  `ExUnit.start/0`), not per test — per-test registry starts are themselves
  a collision (two async setups racing `start_link` on the same name).
- Call-site shape: `{pid, name} = start_supervised_singleton!({Sweeper, tick_ms: :manual}, module: Smalt.ArmGateway.LRO.Sweeper)`.

---

## 4. Migration order (FLAKE_LEDGER recurrence-ranked, v26.10.17 ledger)

The ledger's recurrence column is the only non-narrative priority signal.
Order: recurrence DESC, blast radius as tiebreak. CLOSED rows migrate to
lock the fix's mechanism into shared foundations (a CLOSED row whose
private helper drifts re-opens); OPEN-ROTATING rows are NOT mechanically
migratable (fence F6 already retired per fence10-ratio.md §1; F7/F14/F17
are contention dispositions, not helper-shaped).

| Phase | Ledger row(s) | Recur | Site(s) | Foundation consumer | Draft |
|---|---|---|---|---|---|
| P0 | — | — | mix.exs elixirc_paths + Lifecycle move + registries in test_helper | all | §1, §3.4 |
| P1 | F9 | 3 | affidavit_wasm_failclosed fence 10 | (no helper; ratio fence) | `fence10-ratio.md` |
| P2 | F10 | 2+ | egress_dispatch setup resilient_clear | `Store.resilient_clear/1` | §3.2; assert-eventually collapse #3 |
| P3 | F8 | 1 (75-fail blast) | amqp/management_rpc (async: false already landed, i21d) | `Env` audit of its env mutations | §3.3 |
| P4 | F11 + store-lro §2 | 1 | lro_test sweep_until_terminal + sweeper ownership | `AssertEventually` + `Singleton` | `store-lro-wasm.md` §2/§3; `assert-eventually.ex.md` collapse #1 |
| P5 | F1 | 1 | arm_error_corpus poll_until_succeeded | `AssertEventually` | `assert-eventually.ex.md` collapse #2; `store-lro-wasm.md` §3 |
| P6 | F2-F5 | 1 each | corpus/compliance seed hardening | `Store.resilient_setup` (+ `quiescent_read` for shacl fuzz) | `corpus-compliance.md`; §3.2 |
| P7 | — | — | leak-batch residue (≈15 files, env restore spellings) | `Env.with/2` / `put_restored/1` | §3.3 |

Notes on the ordering:
- **F9 outranks F10 despite lower site count** — recur 3 (upgraded
  PERSISTENT-FLAKE per the ledger) and its draft (`fence10-ratio.md`) needs
  no foundation, so it can land the same instant P0 does, in parallel.
- **F8 before F10** is blast radius, not recurrence: management_rpc's async
  wipe produced 75 cross-file failures; its remaining exposure is env-laws,
  hence the `Env` audit rather than a retry-helper migration.
- **F6/F7/F14/F17: no migration** — OPEN-ROTATING rows carry named
  mechanisms (measurement-fence jitter retired at fuzz_test.exs:606-613;
  contention-class dispositions). Migrating them onto retry helpers would
  be narrative, not mechanism: none of them failed for lack of a helper.
- Every phase lands with its own receipt; the ledger row is updated (recur
  + standing) only per the ledger's own stale-by-default law.

---

## 5. Out of scope

- `lib/` sleeps (lib-sleeps.md lanes) and the No-Sleep doctrine's lib laws.
- Budget formatter/gate internals (budget-gate.md owns those; foundations
  only introduces the `:stress` vocabulary it tiers on).
- Call-site migration of the four AssertEventually instances beyond the
  ledger-ranked phases above (assert-eventually.ex.md "Explicitly out of
  scope" still holds).
- Any generated artifact; any git action.
