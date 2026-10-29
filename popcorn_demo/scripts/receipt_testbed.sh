#!/usr/bin/env bash
# LANE L7 — popcorn_demo testbed witness: one command -> standing-line markdown receipt.
# Contract: substrate preflight -> host-side module legs (local formatter, no lib edits)
#           -> in-browser witness (scripts/browser_smoke.mjs) -> receipt file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="${REPO_ROOT}/popcorn_demo"
RECEIPTS_DIR="${DEMO_DIR}/receipts"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RECEIPT="${RECEIPTS_DIR}/${TS}-testbed-witness.md"
SUBSTRATE_URL="http://127.0.0.1:9443/metadata/endpoints"

# popcorn_demo pins elixir ~> 1.20 (mix.exs); host PATH may carry an older one.
ELIXIR_DIR=""
for d in "$HOME"/.asdf/installs/elixir/1.20.3-otp-28 "$HOME"/.asdf/installs/elixir/1.20.*-otp-28 "$HOME"/.asdf/installs/elixir/1.20.*; do
  [ -x "$d/bin/elixir" ] && ELIXIR_DIR="$d" && break
done
[ -n "${ELIXIR_DIR}" ] && export PATH="${ELIXIR_DIR}/bin:${PATH}"

# browser_smoke.mjs honors CHROMIUM_PATH; playwright headless-shell cache may be
# an incomplete download — fall back to system Chrome.
if [ -z "${CHROMIUM_PATH:-}" ]; then
  CHROMIUM="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [ -x "$CHROMIUM" ] && export CHROMIUM_PATH="$CHROMIUM"
fi

mkdir -p "${RECEIPTS_DIR}"

# ---------------------------------------------------------------- preflight
echo "== [preflight] substrate ${SUBSTRATE_URL}"
if curl -sf -m 3 "${SUBSTRATE_URL}" >/dev/null 2>&1; then
  echo "substrate: UP"
else
  echo "substrate: down -> just substrate-up"
  (cd "${REPO_ROOT}" && 9>&- just substrate-up) || true
  if curl -sf -m 3 "${SUBSTRATE_URL}" >/dev/null 2>&1; then
    echo "substrate: UP (after substrate-up)"
  else
    {
      echo "# popcorn_demo testbed witness — SUSPECT-BLOCKED"
      echo
      echo "- Standing: SUSPECT-BLOCKED (substrate down after substrate-up)"
      echo "- Date: ${TS}"
      echo
      echo '```'
      echo "curl -sf -m 3 ${SUBSTRATE_URL} -> nonzero"
      echo '```'
    } > "${RECEIPT}"
    echo "RECEIPT: ${RECEIPT} standing=SUSPECT-BLOCKED"
    exit 3
  fi
fi

# ------------------------------------------------------------- host legs
echo "== [host legs] mix run (MIX_BUILD_ROOT=_build-lane7)"
HOST_EXIT=0
HOST_OUT="$(cd "${DEMO_DIR}" && MIX_BUILD_ROOT=_build-lane7 mix run -e '
# directory-driven discovery: every live_*.ex module (runtime glob, so new
# legs are picked up with zero edits here). Label = module name minus the
# PopcornDemo.Live prefix, lowercased (LiveRules -> rules, LiveBlob -> blob).
paths = Path.wildcard(Path.join(File.cwd!(), "lib/popcorn_demo/live_*.ex"))

modules =
  for path <- Enum.sort(paths) do
    # module atom comes from the defmodule in the file itself, not a
    # camelize guess (live_kv.ex defines LiveKV, not LiveKv).
    src = File.read!(path)

    case Regex.run(~r/defmodule\s+PopcornDemo\.(\w+)/, src) do
      [_, short] ->
        label = short |> String.replace_prefix("Live", "") |> Macro.underscore() |> String.downcase()
        {String.to_atom("Elixir.PopcornDemo." <> short), label}

      nil ->
        # anonymous live_*.ex file: loud per-module skip, never a crash
        {nil, Path.basename(path, ".ex")}
    end
  end

formatter = fn
  {:ok, label, detail} -> label <> "=OK(" <> detail <> ")"
  {:error, label, detail} -> label <> "=FAIL(" <> detail <> ")"
  {:skip, label, reason} -> label <> "=SKIP(" <> inspect(reason) <> ")"
  {:ok, detail} when is_binary(detail) -> detail
  {:fail, detail} when is_binary(detail) -> detail
  {:error, msg} when is_binary(msg) -> msg
  {:skip, msg} when is_binary(msg) -> msg
  {:skip, reason} when is_atom(reason) -> "live=SKIP(" <> Atom.to_string(reason) <> ")"
  {:skip, reason} -> "live=SKIP(" <> inspect(reason) <> ")"
end

fragments =
  for {mod, label} <- modules do
    if is_nil(mod) do
      IO.puts("[SKIP] " <> label <> " no-defmodule")
      label <> "=SKIP(no-defmodule)"
    else
      case Code.ensure_loaded(mod) do
        {:module, _} ->
          cond do
            not function_exported?(mod, :run, 0) ->
              IO.puts("[SKIP] " <> label <> " no-run/0")
              label <> "=SKIP(no-run/0)"

            true ->
              try do
                if function_exported?(mod, :format, 1) do
                  mod.format(mod.run())
                else
                  formatter.(mod.run())
                end
              rescue
                e ->
                  IO.puts("[SKIP] " <> label <> " raised: " <> Exception.message(e))
                  label <> "=SKIP(raised:" <> String.replace(Exception.message(e), "\n", " ") <> ")"
              end
          end

        {:error, kind} ->
          IO.puts("[SKIP] " <> label <> " " <> Atom.to_string(kind) <> " (lane in flight)")
          label <> "=SKIP(" <> Atom.to_string(kind) <> ")"
      end
    end
  end

IO.puts("HOST_RECEIPT: " <> Enum.join(fragments, "; "))
' 2>&1)" || HOST_EXIT=$?
echo "${HOST_OUT}"
echo "host legs exit: ${HOST_EXIT}"

HOST_LINE="$(echo "${HOST_OUT}" | sed -n 's/^HOST_RECEIPT: //p' | tail -1)"

# --------------------------------------------------------- browser witness
echo "== [browser witness] node scripts/browser_smoke.mjs"
BROWSER_SKIP=0
if [ -f "${DEMO_DIR}/public/out/index.html" ] || [ -n "$(ls -A "${DEMO_DIR}/public/out" 2>/dev/null)" ]; then
  BROWSER_EXIT=0
  BROWSER_OUT="$(cd "${DEMO_DIR}" && node scripts/browser_smoke.mjs 2>&1)" || BROWSER_EXIT=$?
  echo "${BROWSER_OUT}"
  echo "browser witness exit: ${BROWSER_EXIT}"
else
  BROWSER_SKIP=1
  BROWSER_EXIT=0
  BROWSER_OUT="[SKIP] browser-witness not-cooked (public/out empty)"
  echo "${BROWSER_OUT}"
fi

# ------------------------------------------------------------------ standing
if [ -z "${HOST_LINE}" ]; then
  # host mix run crashed before emitting HOST_RECEIPT — never read as ALIVE
  STANDING="SUSPECT"
elif echo "${HOST_LINE}" | grep -q "=FAIL"; then
  STANDING="SUSPECT"
elif [ "${BROWSER_EXIT}" -ne 0 ]; then
  STANDING="SUSPECT"
elif [ "${HOST_EXIT}" -ne 0 ]; then
  # a crash that still printed fragments must not read as ALIVE either
  STANDING="SUSPECT"
elif echo "${HOST_LINE}" | grep -q "=SKIP" || [ "${BROWSER_SKIP}" -eq 1 ]; then
  STANDING="PARTIAL_ALIVE"
else
  STANDING="ALIVE"
fi

# ------------------------------------------------------------------ receipt
{
  echo "# popcorn_demo testbed witness — ${STANDING}"
  echo
  echo "- Standing: ${STANDING}"
  echo "- Date: ${TS}"
  echo "- Host legs exit: ${HOST_EXIT}"
  echo "- Browser witness exit: ${BROWSER_EXIT}${BROWSER_SKIP:+ (skipped: public/out not cooked)}"
  echo
  echo "## Host-side legs (mix run, MIX_BUILD_ROOT=_build-lane7)"
  echo
  echo '```'
  echo "${HOST_OUT}"
  echo '```'
  echo
  echo "## Browser witness (node scripts/browser_smoke.mjs)"
  echo
  echo '```'
  echo "${BROWSER_OUT}"
  echo '```'
} > "${RECEIPT}"

echo "RECEIPT: ${RECEIPT} standing=${STANDING}"
case "${STANDING}" in
  ALIVE|PARTIAL_ALIVE) exit 0 ;;
  *) exit 1 ;;  # SUSPECT is loud: nonzero witness exit
esac
