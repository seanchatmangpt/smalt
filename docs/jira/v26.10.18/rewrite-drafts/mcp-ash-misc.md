# Rewrite drafts: mcp / ash-extension / lro sweeper / misc (v26.10.18)

Status: DRAFT (frozen tree; no edits, no git). Repo: /Users/sac/smalt.
Scope: `test/mcp_test.exs`, `test/ash_extension_test.exs`, `test/lro_test.exs`
(sweeper face only — other lane's drafts checked first, see §3),
`test/trust_profile_deployment_test.exs`, misc sleep sweep (§4).

---

## 1. `test/mcp_test.exs`

### 1a. Lens-4 hostile supervisor swap (lines ~918-943) → `start_supervised!`

Current: `Supervisor.start_link(children, strategy: :one_for_one)`, an
`Application.put_env(:smalt, :doctor_supervisor, sup)` swap, and a manual
`on_exit` doing the env restore plus `Process.exit(sup, :kill)`.

Hazards on HEAD:
- An assert failure between `start_link` and `on_exit` registration leaves the
  hostile supervisor running (kill never registered).
- `Supervisor.start_link/2` links the test process; a crash between start and
  on_exit tears the test process down before the cleanup is registered.
- The kill happens in `on_exit`, after the env restore can already have run —
  ordering of "supervisor dead" vs "env restored" is not guaranteed.

Draft (the only diff; everything else on HEAD stays, including the saved-env
capture and the Chicago-clean real hostile supervisor):

```elixir
  sup =
    start_supervised!({Supervisor, [children, [strategy: :one_for_one]]})

  # Leak fix (i21 batch 3) kept verbatim: restore the PREVIOUS env value.
  saved_supervisor = Application.get_env(:smalt, :doctor_supervisor, Smalt.Supervisor)
  Application.put_env(:smalt, :doctor_supervisor, sup)

  on_exit(fn ->
    Application.put_env(:smalt, :doctor_supervisor, saved_supervisor)
  end)
  # Process.exit(sup, :kill) DELETED — start_supervised! owns the kill.
```

Why it works: ExUnit shuts down `start_supervised!` children after the test
exits and BEFORE `on_exit` callbacks run, so the ordering becomes guaranteed
(supervisor dead → env restored → next test), and a mid-test failure no longer
leaks the supervisor. `start_supervised!` returns the pid, so the env swap
still targets the real supervisor. The env swap itself stays: it is the
surface under test, not a mock.

### 1b. Protocol-version SSOT bridge (second module, lines 1408-1436)

Problem: the bridge test reads the TTL side by regex but observes the runtime
SSOT (`@protocol_version`, a compile-time module attribute on
`Smalt.Mcp.Router`) only through a full wire round-trip. Any second copy of
the version literal outside dispatch (future CLI, descriptor, doc table) can
drift with no fence.

Draft — three tiers; tier A needs one one-line lib edit, named for the
implementing lane (frozen tree here):

```elixir
# lib/smalt/mcp/router.ex — public accessor over the attribute (tier A)
def protocol_version, do: @protocol_version
```

```elixir
defmodule Smalt.Mcp.ProtocolVersionBridgeTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  test "router protocolVersion matches the TTL-authored ema:mcpProtocolVersion" do
    ttl = File.read!(Path.expand("../lib/smalt/mcp/gen/smalt_mcp_surface.ttl", __DIR__))

    assert [_, ttl_version] = Regex.run(~r/ema:mcpProtocolVersion\s+"([^"]+)"/, ttl)

    # Tier A: SSOT accessor — attribute read directly, zero wire.
    assert Smalt.Mcp.Router.protocol_version() == ttl_version

    # Tier B (kept verbatim from HEAD lines 1419-1434): wire round-trip —
    # proves dispatch actually serves the SSOT, not just that the attribute
    # agrees. A second copy inside dispatch would pass tier A only.
    conn =
      conn(:post, "/",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2024-11-05"}
        })
      )
      |> Smalt.Mcp.Router.call([])

    assert conn.status == 200
    decoded = Jason.decode!(conn.resp_body)
    assert decoded["result"]["protocolVersion"] == ttl_version

    # Tier C (optional, cheap): anti-second-copy fence over the generated
    # descriptor — it must not carry its own protocol-version literal.
    desc_src =
      File.read!(Path.expand("../lib/smalt/mcp/generated/mcp_descriptor.ex", __DIR__))

    refute desc_src =~ ~r/"20\d\d-\d\d-\d\d"/,
           "generated descriptor carries its own protocol-version literal — route it through the router SSOT"
  end
end
```

If the tier-C regex over-fires (a description could legitimately embed a
version-looking string), narrow it to a key-pattern
(`~r/protocolVersion"\s*=>\s*"20\d\d/) rather than dropping the tier.

Note: the deliberate literals in the pinning tests above the bridge
(`"initialize pins protocolVersion..."`, line 496) STAY — they are drift pins
by design; the bridge is what makes a spec bump move both sides together.

---

## 2. `test/ash_extension_test.exs` — specimen compiler isolation

Problem: `compile_refused/2` (lines 109-138) runs `Code.compile_string/1` on
the test process inside `Code.with_diagnostics/1`. Two leak channels:

1. Parallel-checker channel: a Spark verifier failure during
   `Code.compile_string` can surface as an async parallel-checker crash
   (Elixir 1.19) — the raise lands on a compiler-worker process, the rescue
   clause misses it, and the crash attributes to whichever suite shares the
   scheduler at that moment.
2. Code-server channel: a refused specimen still defines modules
   (`SmaltTest.AshExtension.Refused.<Name><id>` + its domain) and
   `Code.compile_string` loads them into the global code server;
   partial-compile residency can poison the next `Code.compile_string` in any
   suite. The `unique_integer` naming prevents name collisions but not
   residency.

Draft — run each specimen in a spawned Task, keep the HEAD verdict logic
byte-identical, purge specimen modules after the verdict:

```elixir
  # Specimen refusal: same EITHER-or contract as HEAD (raised
  # Spark.Error.DslError matching `re` OR captured error diagnostic matching
  # `re`; a clean compile with neither = vacuous verifier). Draft changes ONLY
  # the execution context:
  #   (a) the compile runs inside Task.async — an isolated process per
  #       specimen; a parallel-checker crash is contained in the task and
  #       re-raised by Task.await with the specimen's own stacktrace on the
  #       test process, never attributed to a sibling suite;
  #   (b) after the verdict, the specimen's two modules are purged from the
  #       code server so a refused-but-partially-loaded beam cannot poison
  #       the next Code.compile_string.
  @compile_refused_timeout 30_000

  defp compile_refused(source, re) do
    {outcome, diagnostics} =
      Task.await(
        Task.async(fn ->
          Code.with_diagnostics(fn ->
            try do
              Code.compile_string(source)
              :compiled_clean
            rescue
              e -> {:raised, e}
            end
          end)
        end),
        @compile_refused_timeout
      )

    raised? =
      case outcome do
        {:raised, e} ->
          struct_name = e.__struct__ |> Module.split() |> Enum.join(".")
          struct_name == "Spark.Error.DslError" and Regex.match?(re, Exception.message(e))

        _ ->
          false
      end

    diagnostic? =
      Enum.any?(diagnostics, fn d ->
        d.severity in [:error, :warning] and Regex.match?(re, d.message)
      end)

    purge_specimen_modules()

    assert raised? or diagnostic?,
           "expected refusal matching #{inspect(re)} -- got outcome=#{inspect(outcome)} " <>
             "diagnostics=#{inspect(Enum.map(diagnostics, &{&1.severity, &1.message}))}"
  end

  # Purge every Refused specimen module currently resident. Blanket purge of
  # the SmaltTest.AshExtension.Refused namespace is safe: names are
  # unique_integer-suffixed, nothing outside the specimens lives there, and
  # the only other definer is this same suite.
  defp purge_specimen_modules do
    for {m, _} <- :code.all_loaded(),
        match?("Elixir.SmaltTest.AshExtension.Refused." <> _, Atom.to_string(m)) do
      :code.purge(m)
      :code.delete(m)
    end

    :ok
  end
```

Notes:
- `Task.async/1` links to the test process, so a hard crash inside the compile
  still fails THIS test (correct attribution) — it just can no longer surface
  on a compiler-worker process outside the try/rescue.
- The purge runs after the verdict so a diagnostic-bearing failure is asserted
  before cleanup mutates any state; purge errors (`:false` from delete after a
  failed purge) are ignored — residency best-effort, verdict is the contract.
- `specimen/3` on HEAD is untouched: unique naming stays, isolation is
  additive.

---

## 3. `test/lro_test.exs` sweeper — NOT re-drafted here (checked upstream first)

Per the work order, the other lane's drafts were read before drafting:

- `rewrite-drafts/assert-eventually.ex.md` covers the sweeper **retry** face:
  instance i21 maps `sweep_until_terminal/3` (lro_test.exs:1181) onto the
  shared bounded-poll primitive.
- `rewrite-drafts/lib-sleeps.md` redesigns 2-4 cover the **lib/** side
  (`LRO.await` monitor/registry; sweeper `eviction_pass` atomic
  finalize-then-evict).

Residual NOT covered upstream (flagged for the coordinator; conversion shape
included so it can be assigned without re-derivation): the sweeper tests'
setup-side **elapsed-delay sleeps** — `Process.sleep(delay + margin)` at
lro_test.exs lines 144, 338, 402, 651, 672, 701, 734. These wait out
`:lro_delay_ms` so the op is past its flip deadline before a poll/sweep.

Lawful rewrite: **backdate `startedAtMs`** instead of sleeping. Completion is
a pure function of the stored record + clock (the suite's own comment, line
133), so seeding via `Store.put` with
`startedAtMs = System.system_time(:millisecond) - delay - margin` is the
deterministic equivalent of waiting, with zero wall-clock cost and zero
scheduling flake. Keep the AssertEventually poll wrapper around the sweep/poll
itself (that face is already drafted upstream). `wait_terminal`'s existing
20 ms poll loop is deadline-bounded and stays.

Classification of this file's remaining sleeps:
- lines 144/338/402/651/672/701/734 — elapsed-delay class: backdate, drop the sleep.
- line 822 (`Process.sleep(5)` inside the stickiness loop) and the
  `wait_terminal` poll loop — bounded poll backoff, keep.
- line 1147 (`Process.sleep(60)` before 24 concurrent polls) — elapsed-delay
  class, same backdate rewrite.
- line 1207 (20 ms inside `sweep_until_terminal`) — superseded by the
  upstream AssertEventually draft (i21).

### `test/trust_profile_deployment_test.exs`

Grep result: ZERO sleeps. The suite is pure (`Deployment.validate/2` closed
enum) plus one read-only `current_config/0` (Application env read). Only
rewrite: `use ExUnit.Case, async: false` → `async: true`. Low priority; no
behavioral risk (no writes, no named processes, no app env mutation in the
suite).

---

## 4. Misc sleep sweep (grep over test/, `Process.sleep|:timer.sleep`)

Files currently containing sleeps (grep -l, real output):
mcp_test.exs, telemetry_test.exs, admission_projection_test.exs,
lro_test.exs, affidavit_wasm_failclosed_test.exs,
smalt_ets_composite_identity_test.exs, eventgrid_conformance_test.exs,
affidavit_ingestion_functor_test.exs, smalt_affidavit_wasm_test.exs,
arm_error_corpus_test.exs, tls_test.exs, store_dets_test.exs,
kv_tls_test.exs, enclave_doctor_severity_test.exs,
metadata_endpoints_test.exs, smalt_ets_baseline_identity_test.exs,
smalt_arm_gateway_test.exs, mcp_wire_test.exs, pplan_test.exs,
test_helper.exs (plus this lane's four files, handled above).

`test/vault/` does not exist in this tree (checked). The files above outside
this lane's assigned scope are enumerated here so the coordinator can
partition the remaining misc sweep; they are not drafted in this file.
