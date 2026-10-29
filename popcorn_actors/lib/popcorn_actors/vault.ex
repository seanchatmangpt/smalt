defmodule PopcornActors.Vault do
  @moduledoc """
  MOONSHOT lane 7 — vault-secrets actor for the in-VM (WASM) slice.

  Shallowest vault surface per the lith-actor-extraction audit: put/get/version
  in pure Elixir — no :crypto, no file, no socket. The deep crypto surface
  (KD-LITH-02) is explicitly out of this slice.

  Bridge shape follows lane 2's direct-bridge witness: a raw registered process
  receiving `{:wasm, req}` and replying through `Popcorn.JS.send` with a map
  `req: req, reply: result`. The GenServer path is dead on the browser VM
  (lane 2 witness), so this is a plain receive loop, not a GenServer. Host-side
  it is just a plain process — `mix test`-able without Popcorn.

  Wire protocol (string requests/replies over the ETF bridge):
      "put|<name>|<value>"   -> "ok|<name>|<version>|<backend>"
      "get|<name>"           -> "ok|<value>"            | "err|not_found"
      "version|<name>"       -> "ok|<version>"          | "err|not_found"

  `<backend>` witnesses whether `:ets.new/2` works on the target runtime
  (KD-LITH-01 probe): `ets` or `pdict`. State is carried in the loop argument
  either way, so the actor is correct regardless of which backend the runtime
  admits; the probe result rides every put reply.
  """

  @spec start() :: pid()
  def start do
    pid = :erlang.spawn(fn -> loop(%{}, probe_backend()) end)
    true = :erlang.register(:vault, pid)
    pid
  end

  # KD-LITH-01 probe: can this runtime create an ETS table at all?
  defp probe_backend do
    try do
      ref = :ets.new(:vault_tab, [:set, :public])
      :ets.insert(ref, {:probe, true})
      _ = :ets.lookup(ref, :probe)
      _ = :ets.delete(ref)
      :ets
    rescue
      _ -> :pdict
    catch
      _, _ -> :pdict
    end
  end

  defp loop(state, backend) do
    receive do
      {:wasm, req} ->
        {state2, reply} = handle(req, state, backend)
        :erlang.apply(:"Elixir.Popcorn.JS", :send, [%{req: req, reply: reply}])
        loop(state2, backend)
    end
  end

  @doc "Pure handler: `{new_state, reply_string}` for one wire request."
  def handle(req, state, backend) do
    case String.split(req, "|", parts: 3) do
      ["put", name, value] ->
        version =
          case Map.get(state, name) do
            {_, count} -> count + 1
            nil -> 1
          end

        {Map.put(state, name, {value, version}),
         "ok|" <> name <> "|" <> Integer.to_string(version) <> "|" <> Atom.to_string(backend)}

      ["get", name] ->
        case Map.get(state, name) do
          {value, _count} -> {state, "ok|" <> value}
          nil -> {state, "err|not_found"}
        end

      ["version", name] ->
        case Map.get(state, name) do
          {_value, count} -> {state, "ok|" <> Integer.to_string(count)}
          nil -> {state, "err|not_found"}
        end

      _ ->
        {state, "err|bad_request"}
    end
  end
end
