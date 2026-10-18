# Rewrite drafts: corpus + compliance test scaffolding consolidation

Scope: `test/corpus/helper.exs`, `test/corpus/shacl_fuzz.exs`,
`test/corpus/tags_normalization.exs`, `test/compliance/c1_arm.exs`,
`test/compliance/c3_cosmos.exs`, `test/compliance/c4_blob.exs`.

Tree: `/Users/sac/smalt` (READ-ONLY — these are drafts, nothing edited).

## Design decisions (first principles)

1. **One canonical `resilient_clear`** lives in `Smalt.Corpus.Helper`
   (`resilient_clear/1` with optional `post_seed` fun). The four private
   copies (helper, c1, c3, c4) were drift-prone: c3's copy does NOT have the
   `{:already_started, _}` monitor-wait that c1/c4 have (it returns `:ok`
   immediately on an already-started Store whose tables may be mid-death —
   a real divergence between receipted copies). The helper version is the
   superset and becomes the only implementation.
2. **One `AssertEventually` module** in the helper: deadline-bounded,
   quiescent-double-read polling for anything that today sleeps a fixed
   amount and hopes. Two entry points:
   - `assert_eventually!(label, deadline_ms, fun)` — poll until `fun()`
     returns `{:ok, value}` (or raise with the last value after deadline).
   - `quiescent_read(read_fun, opts)` — the shacl-fuzz snapshot mechanism
     generalized: retry until two consecutive reads agree (torn-read
     discard), rescuing the dead-table `ArgumentError` and `GenServer`
     `:exit` timeouts, bounded. Sleeps only on disagreement (quiet path
     costs zero wall-clock), preserving the i22 double-read law.
3. **`start_supervised!/1` for Bandit listeners** in c1/c3/c4 setup. The
   manual `{:ok, server} = Bandit.start_link(...)` + `on_exit(Process.exit)`
   pair leaks the listener if setup asserts after the start; supervised
   startup ties lifecycle to the test process and removes the
   `stop_server/1` kill-fallback helpers entirely (Supervisor cleanup is
   ordered before `on_exit` runs).
4. **Receipted verdict-class assertions are contract** — every assert on a
   verdict atom, status code, header byte value, error `code`, envelope
   shape, pinned row tuple, and every "mutant-kill" comment is preserved
   verbatim. Where a section is unchanged the draft says `UNCHANGED
   (verbatim)` with source line ranges instead of restating it.
5. **Fixed sleeps / wall-clock bounds are flagged, not silently converted.**
   See the flag register at the end. Rule applied: a sleep that is
   *load-bearing semantics* (fixed-window rate limit, LRO Retry-After=1s
   window) stays a wall-clock bound and is typed with a named module
   attribute + receipt citation; a sleep that is *polling hope* becomes
   `AssertEventually`.

---

## 1. `test/corpus/helper.exs` — full rewrite (canonical implementations)

```elixir
# Shared dispatch helpers for the incidents-as-permanent-evals replay corpus
# (test/corpus_test.exs). Loaded by corpus_test.exs BEFORE the corpus modules
# so every family shares one in-process dispatch path (Plug.Test against the
# real routers, real Store — Chicago, no mocks).
defmodule Smalt.Corpus.Helper do
  @moduledoc false

  import Plug.Test
  import Plug.Conn

  alias Smalt.ArmGateway.Router
  alias Smalt.EgressRouter
  alias Smalt.Store

  @arm_opts Router.init([])
  @egress_opts EgressRouter.init([])

  @doc "Ensure the shared Store is up and empty for a corpus test."
  def ensure_store do
    resilient_clear()
    :ok
  end

  @doc """
  i22 hardening (docs/jira/v26.10.17/receipts/i21-ets-race-fix.md): the
  window between ensure-store-up and `Store.clear/0` is racy when an async
  sibling suite tears the shared app tree down — the named ETS tables die
  mid-clear. Bounded typed retry, rescuing ONLY the exact dead-table
  ArgumentError; past the bound it raises loudly (never a silent pass).

  CANONICAL implementation (this window): the former private copies in
  test/compliance/c1_arm.exs, c3_cosmos.exs, c4_blob.exs are deleted in
  favor of this one. `post_seed` (default identity) runs inside the same
  retry window so a seed racing the same dead-table window is retried too
  — this is what c1's subscription seed needs and what its local copy
  specialized.
  """
  @retry_bound 50
  @retry_backoff_ms 10
  @dead_table_msg "table identifier does not refer to an existing ETS table"

  def resilient_clear(post_seed \\ fn -> :ok end) do
    do_resilient_clear(post_seed, @retry_bound)
  end

  defp do_resilient_clear(_post_seed, 0) do
    raise "shared Store unavailable after #{@retry_bound} retries " <>
            "(i22 corpus-seed hardening, canonical Smalt.Corpus.Helper)"
  end

  defp do_resilient_clear(post_seed, remaining) do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    post_seed.()
  rescue
    e in ArgumentError ->
      if Exception.message(e) == @dead_table_msg do
        Process.sleep(@retry_backoff_ms)
        do_resilient_clear(post_seed, remaining - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Deadline-bounded poll. `fun` returns `{:ok, value}` to stop or any other
  term to keep polling. Raises with the last observed value past the
  deadline — loud, never a silent pass. Replaces fixed-sleep-and-hope
  polling (c1 `poll_until_terminal/3`'s 20ms x 100 grid).
  """
  def assert_eventually!(label, deadline_ms, fun, poll_every_ms \\ 20) do
    started = System.monotonic_time(:millisecond)

    do_poll(label, started + deadline_ms, deadline_ms, fun, poll_every_ms, nil, started)
  end

  defp do_poll(label, deadline, deadline_ms, fun, every, last, now) when now >= deadline do
    flunk("assert_eventually!(#{inspect(label)}) timed out after #{deadline_ms}ms; " <>
            "last observation: #{inspect(last)}")
  end

  defp do_poll(label, deadline, deadline_ms, fun, every, _last, _now) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        Process.sleep(every)
        do_poll(label, deadline, deadline_ms, fun, every, other, System.monotonic_time(:millisecond))
    end
  end

  defp flunk(msg), do: raise(ExUnit.AssertionError, message: msg)

  @doc """
  Quiescent double-read (i22 snapshot hardening, mechanism per
  docs/jira/v26.10.17/receipts/i20b-contention-mechanism.md):
  `read_fun/0` is called repeatedly until two consecutive reads AGREE (a
  torn mid-write read is discarded). Rescues only the typed faces:
  the dead-table ArgumentError and the 5000ms GenServer.call :exit cliff.
  Sleeps only after a disagreement or typed rescue — the quiet path is
  back-to-back reads, zero wall-clock. Past `:retries`, raises loudly.
  """
  @quiesce_retries 20
  @quiesce_backoff_ms 25
  @store_call_timeout_ms 5000

  def quiescent_read(read_fun, opts \\ []) do
    retries = Keyword.get(opts, :retries, @quiesce_retries)
    backoff = Keyword.get(opts, :backoff_ms, @quiesce_backoff_ms)
    do_quiescent_read(read_fun, retries, backoff, :first_read)
  end

  defp do_quiescent_read(_read_fun, 0, _backoff, _prev) do
    raise "quiescent_read: shared Store unreadable after #{@quiesce_retries} quiesce retries " <>
            "(i22 hardening) — raising loudly, never a silent pass"
  end

  defp do_quiescent_read(read_fun, remaining, backoff, prev) do
    cur = read_fun.()

    if cur == prev do
      cur
    else
      if prev != :first_read, do: Process.sleep(backoff)
      do_quiescent_read(read_fun, remaining - 1, backoff, cur)
    end
  rescue
    e in ArgumentError ->
      if Exception.message(e) == @dead_table_msg do
        Process.sleep(backoff)
        do_quiescent_read(read_fun, remaining - 1, backoff, prev)
      else
        reraise e, __STACKTRACE__
      end
  catch
    :exit, {:timeout, {GenServer, :call, [_store, _req, @store_call_timeout_ms]}} ->
      Process.sleep(backoff)
      do_quiescent_read(read_fun, remaining - 1, backoff, prev)
  end

  @doc """
  ARM control-plane dispatch (port 9443 surface): method, path, optional
  body map, optional headers list.
  """
  def arm(method, path, body \\ %{}, headers \\ []) do
    conn =
      if body == %{} and method in [:get, :head, :delete] do
        conn(method, path)
      else
        conn(method, path, Jason.encode!(body))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> Router.call(@arm_opts)
  end

  @doc """
  Data-plane dispatch (port 8443 surface) through the real EgressRouter.
  `body` may be a map (JSON-encoded) or an iodata/binary.
  """
  def egress(method, path, body \\ %{}, headers \\ []) do
    payload =
      cond do
        is_map(body) and body == %{} and method in [:get, :head, :delete] -> ""
        is_map(body) -> Jason.encode!(body)
        true -> body
      end

    conn(method, path, payload)
    |> put_req_header("content-type", "application/json")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> EgressRouter.call(@egress_opts)
  end

  @doc "Decode a JSON response body."
  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "ARM error envelope code."
  def code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ -> nil
    end
  end
end
```

Notes:
- `arm/egress/json/code` are byte-identical to the current tree (the whole
  corpus dispatches through them; changing them changes every receipt).
- `assert_eventually!` returns the `{:ok, value}` payload so callers can
  assert on the terminal body directly.
- The `post_seed/0` arity is the consolidation of c1's specialized
  `resilient_clear(post_seed)` — c1 currently retries `Store.clear` but
  runs its subscription seed AFTER the retry loop returns; a dead-table
  hit during the seed itself would crash un-retried. Moving the seed
  inside the window closes that seam.

---

## 2. `test/corpus/shacl_fuzz.exs` — consolidation draft

Header comment block (INCIDENT → FIX → FENCE, lines 1–25): UNCHANGED
(verbatim).

`defmodule` header, `@seed`, `@total`, `@families`, `@sub`, `@rg_prefix`,
setup, the L2 test, the fuzz-sweep test, payload generator, pinned rows,
dispatch/classification helpers: **assertions UNCHANGED (verbatim,
source lines 26–460)**. The verdict vocabulary is the corpus contract and
is not touched: `:admitted`, `:typed_refusal`, `:parse_typed`,
`:untyped_crash`, `:server_error`, `:untyped_refusal`, `:l3_violation`;
the vacuity guard (`zero refusals — generator is vacuous`) and the
`timeout: 180_000` typed tag both stay.

Only the snapshot tail (source lines 471–543) is replaced — the private
quiesce machinery moves onto the helper's canonical `quiescent_read/2`:

```elixir
  # ---------------------------------------------------------------------------
  # i22 snapshot hardening (mechanism per
  # docs/jira/v26.10.17/receipts/i20b-contention-mechanism.md + i22 report):
  #   1. Subscription-scoped key sets — the L3 law can only be violated by
  #      keys under OUR /subscriptions/fuzz-sub/ id; async siblings write
  #      other subscriptions' rows into the same shared table and those
  #      foreign inserts are the interference term (filtered out here).
  #   2. Quiescent double-read via Smalt.Corpus.Helper.quiescent_read/2 —
  #      two consecutive agreeing reads, dead-table + 5000ms-call-cliff
  #      typed rescues, bounded, loud past the bound. Canonical now; the
  #      private copy is deleted.
  # ---------------------------------------------------------------------------
  @snapshot_scope "/subscriptions/#{@sub}/"

  defp snapshot do
    read = fn table ->
      table
      |> Store.keys()
      |> Enum.filter(fn k ->
        is_binary(k) and String.contains?(String.downcase(k), @snapshot_scope)
      end)
      |> Enum.sort()
    end

    Helper.quiescent_read(fn ->
      {read.(:smalt_resources), read.(:smalt_resource_groups)}
    end)
  end
```

(Add `alias Smalt.Corpus.Helper, as: Helper` at the module top; the setup
line becomes `Helper.resilient_clear()` — same call as today via the
full name, either is fine, pick the alias once.)

Preserved invariants named explicitly so review does not have to diff:
- Scope filter stays `String.contains?(String.downcase(k), @snapshot_scope)` —
  the downcase + substring form is what de-fanged the async-sibling
  interference; do not "tighten" to prefix equality.
- Backoff constants `20` retries / `25ms` move into the helper defaults;
  the values are unchanged from the receipted copy.
- The first-two-reads-fast-path (no sleep until a disagreement) is the
  helper's quiet path — same cost model.

Flagged (unchanged, see register): the `timeout: 180_000` test tag is a
receipted wall-clock bound (soak C run 2) — it is not a polling sleep and
stays.

---

## 3. `test/corpus/tags_normalization.exs` — consolidation draft

No sleeps, no local Store scaffolding, no LRO polling. The file already
rides the helper (`ensure_store/0` in setup). Changes only:

1. Header comment (lines 1–17): UNCHANGED (verbatim — it is the null-vs-empty
   parity law history).
2. All three tests: **assertions UNCHANGED (verbatim, source lines 32–86)**.
3. Setup: no change needed (`ensure_store/0` already routes through the
   canonical `resilient_clear`). Optionally state the dependency:

```elixir
  setup do
    # routes through the canonical Helper.resilient_clear/1 (i22 hardening)
    :ok = ensure_store()
  end
```

Nothing else in this file touches shared seams. It is the smallest
consumer of the helper API and doubles as its smoke test.

---

## 4. `test/compliance/c1_arm.exs` — consolidation draft

Every `test` block: **assertions UNCHANGED (verbatim, source lines
96–789)** — all receipted pins (v4-GUID regex, `x-ms-request-id` == 36,
`MissingApiVersionParameter` message bytes, KD-78 monotonic re-pins,
pagination `$skip`/`maxitempages` arithmetic including the exact
`[200,200,200,200,200,429,429,429,429,429]` window, systemData constant
`"2026-01-01T00:00:00.0000000+00:00"`, row-5b Failed-operation envelope)
are contract.

Replaced: setup scaffolding, `poll_until_terminal/3`, and the private
i22 tail (`resilient_clear`/`ensure_store`, source lines 800–846).

```elixir
  setup context do
    Helper.resilient_clear(fn ->
      Store.put(:smalt_subscriptions, @sub, %{
        "id" => "/subscriptions/#{@sub}",
        "subscriptionId" => @sub,
        "displayName" => "Sovereign Smalt Subscription",
        "state" => "Enabled"
      })
    end)

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)
    Application.put_env(:smalt, :lro_delay_ms, 0)

    port = free_port()

    # start_supervised!: listener lifecycle is tied to the test process —
    # no on_exit Process.exit, no orphaned Bandit on a mid-setup failure.
    start_supervised!({Bandit, plug: Smalt.ArmGateway.Router, port: port})

    on_exit(fn ->
      Application.put_env(:smalt, :auth_mode, prev_auth || :anonymous)
    end)

    {:ok, port: port, test_name: context.test}
  end
```

with `alias Smalt.Corpus.Helper` added at module top. Delete the private
`resilient_clear/2`, `ensure_store/0` tail entirely (the helper's
`post_seed` arity covers the subscription-seed specialization, and the
seed now sits inside the retry window — see helper notes).

LRO polling helper replaced:

```elixir
  # LRO poll: deadline-bounded, not a fixed 20ms x 100 grid. The terminal
  # condition is the wire's own 200; the InProgress 202 keeps the loop hot.
  @lro_poll_deadline_ms 10_000

  defp poll_until_terminal(port, async_url) do
    # The gateway advertises the authority the client actually used (row 10,
    # fixed): strip to the path and probe through the same listener.
    %URI{path: path} = URI.parse(async_url)

    Helper.assert_eventually!("LRO terminal #{async_url}", @lro_poll_deadline_ms, fn ->
      case get!(port, path) do
        {200, _h, body} -> {:ok, {200, json(body)}}
        {202, _h, _body} -> :in_progress
        {status, _h, body} -> flunk("unexpected poll status #{status}: #{body}")
      end
    end)
  end
```

(Keep the arity-3 clauses deleted; the `attempts \\ 100` grid becomes the
deadline. The `flunk("LRO never reached terminal status")` semantics is
preserved by `assert_eventually!/4`'s loud deadline raise.)

Flagged (unchanged, see register): the rate-limit window-alignment and
window-expiry sleeps, and `@retry_after`-driven `retry-after == "1"` pins.

---

## 5. `test/compliance/c3_cosmos.exs` — consolidation draft

Every `test` block: **assertions UNCHANGED (verbatim, source lines
47–899)** — continuation-token grammar regexes, forged/malformed 400 legs,
scope/container binding courts, round-trip emit→resume→terminate
partitions, throttle `[201,201,201,201,201,429,...]` split,
master-key HMAC engine probe, session-token monotonicity: all contract.

Replaced: setup Bandit lifecycle, and the private i22 tail (source lines
1031–1062 — NOTE: this is the copy that lacks the monitor-wait on
`{:already_started, _}`; deleting it is itself a defect fix, logged below).

```elixir
  alias Smalt.Corpus.Helper

  setup do
    Helper.resilient_clear()

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)

    port = free_port()
    :persistent_term.put({__MODULE__, :port}, port)

    start_supervised!({Bandit, plug: Smalt.EgressRouter, port: port})

    on_exit(fn ->
      Application.put_env(:smalt, :auth_mode, prev_auth || :anonymous)
    end)

    {:ok, port: port}
  end
```

Delete: `stop_server/1` (Supervisor-owned now), the private
`resilient_clear/1` + `ensure_store/0`. Keep everything else in the
helpers section (`req/req!/header_map/create_*/get_doc/session_token_for/
port/token_lsn/free_port`) UNCHANGED.

Defect logged by this consolidation (pre-existing, not session-introduced):
c3's private `ensure_store/0` returned `:ok` on `{:already_started, _}`
without checking that `:smalt_subscriptions` (or any table) actually
exists — the exact mid-teardown window the monitor-wait in c1/c4 and the
helper defend against. The canonical helper copy closes it; no receipted
assertion depended on the weaker behavior.

The save-prev/`Process.put` leak-court pattern around `:cosmos_ru_limit`
and `:cosmos_master_key` (i21-leak-batch2) is UNCHANGED — it is a receipted
mechanism, not scaffolding drift.

No fixed sleeps exist in c3 today beyond the typed rescues the helper now
owns. Nothing new flagged.

---

## 6. `test/compliance/c4_blob.exs` — consolidation draft

Every `test` block: **assertions UNCHANGED (verbatim, source lines
51–1425)** — WORM/ContainerLocked, legal-hold and immutabilityPolicy
header pins, `assert_std_blob_headers/1` (kept as the module-local fence
combinator: it is a verdict-class assertion itself), all lens-4/5/6
std-header and conditional-precedence courts, delimiter round-trip
partitions, the 503 RouteNotReady beam-hide court (real degraded store,
no mock), the XML-vs-JSON 416 divergence fence: all contract.

Replaced: setup Bandit lifecycle, and the private i22 tail (source lines
1499–1544).

```elixir
  alias Smalt.Corpus.Helper

  setup do
    Helper.resilient_clear()

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)

    port = free_port()
    :persistent_term.put({__MODULE__, :port}, port)

    start_supervised!({Bandit, plug: Smalt.EgressRouter, port: port})

    on_exit(fn ->
      Application.put_env(:smalt, :auth_mode, prev_auth || :anonymous)
    end)

    {:ok, port: port}
  end
```

Delete: `stop_server/1`, the private `resilient_clear/1` + `ensure_store/0`.
Keep `req/req!/normalize_opts/header_map/acct/cont/port/free_port` and the
hoisted `@v4_guid` (with its lens-9 compile-order comment) UNCHANGED.

One caution carried from the current tree: c4's lens-5 503 test hides the
`BlobStorage.beam` and restores it in `after` — `start_supervised!` does
not interact with that mechanism (the listener is already up; the purge is
module-level), so the court is untouched.

No fixed sleeps in c4 beyond helper-owned rescues. Nothing new flagged.

---

## Fixed-sleep / wall-clock bound register (flagged, not silently changed)

| # | Site | Current | Class | Draft disposition |
|---|------|---------|-------|-------------------|
| F1 | c1 rate-limit test: `Process.sleep(1000 - rem(ms, 1000) + 5)` | window alignment | LOAD-BEARING wall-clock (fixed-window semantics; makes the admit count exactly assertable) | KEEP verbatim. Typed with a comment naming the semantics; converting to polling would change the test's subject. |
| F2 | c1 rate-limit test: `Process.sleep(1100)` before the post-expiry 200 assert | window expiry | LOAD-BEARING wall-clock (pins `count > limit` reset on the 1s window roll) | KEEP verbatim, same reasoning. |
| F3 | c1 `poll_until_terminal/3`: 20ms fixed sleep x up to 100 attempts | polling hope | FIXED GRID — replaced by `Helper.assert_eventually!/4` with a 10s deadline (larger headroom than 100x20ms=2s under suite load; deadline raise preserves the loud-flunk semantics). |
| F4 | helper/c1/c3/c4 `resilient_clear` 10ms backoff x 50 | typed-rescue backoff | BOUNDED RETRY — consolidated into the canonical helper; constants unchanged (`@retry_bound 50`, `@retry_backoff_ms 10`). |
| F5 | shacl-fuzz snapshot 25ms backoff x 20 quiesce retries (+ GenServer 5000ms cliff rescue) | typed-rescue backoff | BOUNDED RETRY — consolidated into `Helper.quiescent_read/2`; constants unchanged. Quiet path (agreeing reads) still costs zero wall-clock. |
| F6 | shacl-fuzz `@tag timeout: 180_000` | suite-load headroom | RECEIPTED bound (soak C run 2, receipts/i22-soak-c.md) | KEEP, typed comment already present. |
| F7 | c1 LRO `Application.put_env(:smalt, :lro_delay_ms, 0)` | config, not sleep | not a bound | unchanged. |

Items F1/F2 are the only remaining raw wall-clock sleeps in scope after
this consolidation; both are semantics, not synchronization, and are
flagged so a future sweep does not "fix" them.

## Non-goals / explicitly untouched

- All receipted verdict-class assertions and pinned rows (shacl-fuzz
  `pinned_rows/0` tuples 1:1; all compliance status/header/code pins).
- `lib/` (read-only tree; no production change is proposed or implied).
- The GAP/KD registers — no flips proposed; nothing here closes a gap.
- c1's `test_name` context return, c3/c4 `:persistent_term` port plumbing,
  and the `free_port/0` probe (still required: `start_supervised!` needs
  the port chosen before start).

## Verification plan (for the implementing lane)

1. `mix test test/corpus_test.exs` — full corpus green, verdict counts
   byte-equal to the pre-rewrite run (the sweep prints
   `[shacl-fuzz] verdicts:` — diff it against the receipted run).
2. `mix test test/compliance_test.exs` — c1/c3/c4 green.
3. `just docs-dod-check` still green (no receipt-path changes).
4. `grep -rn "Process.sleep" test/corpus test/compliance` — expect only
   F1, F2, and the helper-owned constants; anything else is un-flagged
   drift.
