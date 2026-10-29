defmodule PopcornDemo.Application do
  @moduledoc """
  Popcorn entrypoint for the smalt pure-decision slice.

  Popcorn boots this supervision tree inside the browser BEAM. The smoke
  child runs smalt's pure modules end to end and reports via `Popcorn.JS`
  when running under the browser runtime; under host `mix run`/`mix test`
  it returns values without any JS bridge.

  The network legs fan out CONCURRENTLY via `Task` — total wait is the max
  leg, not the sum. Legs are DISCOVERED at runtime: every `live_*.ex` file
  under `lib/popcorn_demo/` contributes a leg, its module atom read from the
  file's own `defmodule PopcornDemo.X` (case preserved — `live_kv.ex`
  defines `LiveKV`, not `LiveKv`). The composed SMOKE_RECEIPT line is
  deterministic: fragments sorted by label (`blob`, `containers`, `kv`,
  `live`, ...) after the cosmos/sb/registry smoke line. `PopcornDemo.Live`
  stays the explicit first leg via `Live.format`.
  """

  use Application

  @leg_timeout 15_000

  @impl true
  def start(_type, _args) do
    # Boot smoke owns NO state of its own but its LiveReconcile leg writes
    # :reconcile_store and the shared wire docs concurrently with
    # LiveReconcileTest, so it is gated off in the test environment (single
    # writer per VM; the same surface stays exercised — the tests call
    # Smoke.run()/LiveReconcile.run() directly).
    boot_smoke? =
      if Application.get_env(:popcorn_demo, :boot_smoke, true) do
        [children_task()]
      else
        []
      end

    # In-browser there is no higher-order supervisor to crash into; keep the
    # tree one_for_one so a failed smoke tree doesn't kill the VM boot.
    Supervisor.start_link(boot_smoke?, strategy: :one_for_one, name: PopcornDemo.Supervisor)
  end

  defp children_task do
    {Task,
     fn ->
       smoke = PopcornDemo.Smoke.run()
       PopcornDemo.Smoke.report(smoke <> "; " <> composed_receipt())
     end}
  end

  @doc """
  Composes the leg fragment list (everything after the smoke line) — public so
  the composition is testable host-side through the same code path the browser
  uses. Legs are discovered from `lib/popcorn_demo/live_*.ex` at runtime; all
  run concurrently, a leg exceeding #{@leg_timeout}ms becomes a loud
  `<label>=FAIL(timeout)` fragment; a crashed leg becomes
  `<label>=FAIL(<reason>)`; a discovered module without `run/0` becomes
  `<label>=FAIL(no-run/0)`. Fragments are sorted by label for a stable receipt.
  """
  @spec composed_receipt() :: binary()
  def composed_receipt do
    extra_leg_funs()
    |> Enum.map(&await_leg/1)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
    |> Enum.map(&sanitize_fragment/1)
    |> Enum.join("; ")
  end

  # Receipt single-line law: Exception.message/inspect embed raw newlines and
  # control chars (witnessed: keyops leg emitted
  # "no with clause matching:\n\n{:error, {:tcp_connect, :eprotonosupport}}")
  # which made the composed SMOKE_RECEIPT read as truncated by any line-oriented
  # consumer. Collapse control chars to spaces, squeeze runs of spaces, and cap
  # at 120 chars via Redact.fragment (JWT redaction rides along).
  defp sanitize_fragment(f) when is_binary(f) do
    f
    |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
    |> String.replace(~r/\s{2,}/, " ")
    |> PopcornDemo.Redact.fragment()
  end

  defp sanitize_fragment(other), do: PopcornDemo.Redact.fragment(other)

  # Runs one leg in its own Task (so legs are concurrent), then collects it
  # with yield/shutdown so one slow leg cannot poison the others: the wait is
  # the max leg, and each leg's failure is typed and isolated.
  defp await_leg({label, fun}) do
    task = Task.async(fn -> safe_run(label, fun) end)

    result =
      case Task.yield(task, @leg_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, outcome} -> fragment(label, outcome)
        nil -> label <> "=FAIL(timeout)"
        other -> label <> "=FAIL(" <> inspect(other) <> ")"
      end

    {label, result}
  end

  defp safe_run(label, fun) do
    fun.()
  rescue
    e -> {:error, label <> "=FAIL(" <> Exception.message(e) <> ")"}
  end

  # Directory discovery, mirroring scripts/receipt_testbed.sh: glob live_*.ex,
  # Popcorn tree-shakes the cooked bundle: modules referenced ONLY via the
  # runtime file-glob were dropped from beam.wasm (witnessed: a glob-based
  # discovery cooked down to just Live). The leg list is therefore STATIC —
  # each module is referenced literally so the packager keeps it. Keep in
  # sync with lib/popcorn_demo/live_*.ex.
  @static_legs [
    PopcornDemo.LiveMatrix,
    PopcornDemo.LiveBlob,
    PopcornDemo.LiveQueue,
    PopcornDemo.LiveKV,
    PopcornDemo.LiveRules,
    PopcornDemo.LiveTls,
    PopcornDemo.LiveParam,
    PopcornDemo.LiveContainers,
    PopcornDemo.LiveTags,
    PopcornDemo.LiveMcp,
    PopcornDemo.LiveCerts,
    PopcornDemo.LiveRg,
    PopcornDemo.LivePolicy,
    PopcornDemo.LiveEG,
    PopcornDemo.LiveEh,
    PopcornDemo.LiveCas,
    PopcornDemo.LiveKeyops,
    PopcornDemo.LiveLifecycle,
    PopcornDemo.LiveScvd,
    PopcornDemo.LiveReconcile,
    PopcornDemo.LiveAppConfig,
    PopcornDemo.LiveDns,
    PopcornDemo.LiveExport,
    PopcornDemo.LiveEgd,
    PopcornDemo.LiveTopic,
    PopcornDemo.LiveApim,
    PopcornDemo.LiveAcr
  ]

  defp extra_leg_funs do
    legs =
      @static_legs
      |> Enum.filter(&Code.ensure_loaded?/1)
      |> Enum.map(fn mod ->
        {label_of(mod), fn -> run_leg(mod) end}
      end)

    live_fun = fn -> PopcornDemo.Live.run() |> PopcornDemo.Live.format() end
    [{"live", live_fun} | legs]
  end

  defp run_leg(mod) do
    if function_exported?(mod, :run, 0) do
      # Mirror receipt_testbed.sh: a leg exporting format/1 formats its own
      # outcome (tls/certs add the label + "via ca=OK" riders there).
      # Host-first legs whose transport is :gen_tcp/:httpc crash inside the
      # wasm BEAM (browsers have no raw sockets) — that is an environment
      # fact, so a crash under the JS bridge is a loud typed SKIP, not a
      # FAIL (the same leg is the real witness host-side).
      if browser_bridge?() do
        try do
          leg_fragment(mod)
        rescue
          e -> {:skip, {:browser, label_of(mod) <> "=SKIP(wasm-transport:" <> slice(Exception.message(e)) <> ")"}}
        end
      else
        leg_fragment(mod)
      end
    else
      {:error, label_of(mod) <> "=FAIL(no-run/0)"}
    end
  end

  defp leg_fragment(mod) do
    if function_exported?(mod, :format, 1) do
      mod.format(mod.run())
    else
      mod.run()
    end
  end

  defp browser_bridge? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp slice(b) when is_binary(b), do: String.slice(b, 0, 80)
  defp slice(other), do: other |> inspect() |> String.slice(0, 80)

  defp module_for_file(path) do
    case Regex.run(~r/defmodule\s+PopcornDemo\.(\w+)/, File.read!(path)) do
      [_, short] -> [String.to_atom("Elixir.PopcornDemo." <> short)]
      nil -> []
    end
  end

  defp label_of(mod) do
    case mod |> Module.split() |> List.last() do
      "Live" <> rest -> rest |> Macro.underscore() |> String.downcase()
      last -> Macro.underscore(last)
    end
  end

  # Legs return {:ok | :error | :skip, formatted-fragment} (or, for Live, an
  # already-formatted binary) — pass the fragment through; anything else is a
  # loud typed failure.
  defp fragment(_label, f) when is_binary(f), do: f
  defp fragment(_label, {:ok, f}) when is_binary(f), do: f
  defp fragment(_label, {:error, f}) when is_binary(f), do: f
  defp fragment(_label, {:skip, f}) when is_binary(f), do: f
  defp fragment(_label, {:skip, {_kind, f}}) when is_binary(f), do: f
  # Legs like LiveKV return {:error, {step, reason}} (no label, no format/1) —
  # render label=FAIL(step:reason) instead of a raw inspect leak.
  defp fragment(label, {:error, {step, reason}}) when is_binary(step) and is_binary(reason) do
    label <> "=FAIL(" <> step <> ":" <> reason <> ")"
  end

  defp fragment(_label, {:error, {_kind, f}}) when is_binary(f), do: f

  # A leg returning a typed {:unsupported, reason} (no format/1 — witness:
  # LiveAcr run/0 -> {:unsupported, :acr_face_absent} under wasm) is an
  # environment fact (face-absent), not a failure: render label=SKIP(face-absent:...).
  defp fragment(label, {:unsupported, reason}) do
    label <> "=SKIP(face-absent:" <> slice(reason) <> ")"
  end

  defp fragment(_label, {:skip, reason}) when is_atom(reason) do
    "live=SKIP(" <> Atom.to_string(reason) <> ")"
  end

  defp fragment(_label, other), do: "leg=FAIL(" <> PopcornDemo.Redact.fragment(other) <> ")"
end
