#!/usr/bin/env bash
# scripts/enclave_native.sh — external-Go-free enclave lifecycle runner.
#
# Boots NOTHING: the lifecycle runs in-process (mix run --no-start) with
# only the Store ETS tables started — no sockets, no TLS, no ports, no
# terraform binary, no external Go processes. Emits one receipt row in the
# bench_emit shape (lane id e2-native) per run.
#
# Usage: scripts/enclave_native.sh [fixture-main.tf]
#
# Exit codes: 0 pass / 1 stage failure / 3 harness-skip (fixture missing).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${1:-$ROOT/scripts/tf_fixtures/main.tf}"
RECEIPT="${SMALT_NATIVE_RECEIPT:-$ROOT/tmp/enclave-native.jsonl}"
BUILD_ROOT="${MIX_BUILD_ROOT:-_build}"

if [ ! -f "$FIXTURE" ]; then
  echo "[SKIP] enclave-native: fixture missing: $FIXTURE" >&2
  exit 3
fi

cd "$ROOT"
export MIX_BUILD_ROOT="$BUILD_ROOT"
export MIX_ENV=test

# In-process: --no-start keeps every listener down; only the Store ETS
# owner boots inside the eval. Receipt row = bench_emit shape.
export SMALT_NATIVE_FIXTURE="$FIXTURE"
export SMALT_NATIVE_RECEIPT="$RECEIPT"
MIX_BUILD_ROOT="$BUILD_ROOT" mix run --no-start -e '
  alias Smalt.Enclave.Lifecycle

  # --no-start: boot ONLY the Store ETS owner (no listeners, no ports).
  case :ets.whereis(:smalt_resources) do
    :undefined -> {:ok, _} = Smalt.Store.start_link()
    _ -> :ok
  end

  fixture = System.get_env("SMALT_NATIVE_FIXTURE")
  state_path = "tmp/enclave-native-#{System.system_time(:millisecond)}.tfstate"

  case Lifecycle.run(fixture, state_path: state_path) do
    {:ok, report} ->
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      row =
        Jason.encode!(%{
          "lane" => "e2-native",
          "surface" => "enclave_native_lifecycle",
          "op" => "full_lifecycle",
          "n" => length(report.outcomes),
          "ops_per_sec" => nil,
          "p50_ms" => report.timings_ms.apply,
          "p95_ms" => report.timings_ms.destroy,
          "p99_ms" => report.timings_ms.residue,
          "errors" => 0,
          "machine" => %{
            "parse_ms" => report.timings_ms.parse,
            "apply_ms" => report.timings_ms.apply,
            "plan_ms" => report.timings_ms.plan,
            "synthesize_ms" => report.timings_ms.synthesize,
            "destroy_ms" => report.timings_ms.destroy,
            "residue_ms" => report.timings_ms.residue
          },
          "at" => now,
          "state_path" => report.state_path,
          "resources" => Enum.map(report.outcomes, & &1.id)
        })

      File.mkdir_p!(Path.dirname(System.get_env("SMALT_NATIVE_RECEIPT")))
      File.write!(System.get_env("SMALT_NATIVE_RECEIPT"), row <> "\n", [:append])
      IO.puts("[enclave-native] PASS #{row}")

    {:error, {:stage_failed, stage, reason}} ->
      IO.puts(:stderr, "[enclave-native] FAIL stage=#{stage} reason=#{inspect(reason, limit: 30)}")
      System.halt(1)
  end
'
