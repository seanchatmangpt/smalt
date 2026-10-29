defmodule Smalt.Affidavit.Seal do
  @moduledoc """
  Receipt admission and sealing on top of the affidavit Wasm engine.

  `admit_and_seal/2` takes a dfcm-receipt-shaped map (the five R fields:
  `subject_sha`, `authority`, `consequence`, `replay`, `standing`),
  canonicalizes it to the engine wire format (JCS-style canonical JSON:
  lexicographically sorted keys, compact separators, UTF-8), and calls the
  engine's `affi_admit_and_seal` export. Sealed output is returned as
  `{:ok, %{sealed: binary, receipt: canonicalized_map}}`.

  Fail-closed contract:

    * engine module not loaded / not exported / crashes -> `{:error, :engine_unavailable}`
    * local validation failure                          -> `{:error, {:invalid_receipt, field}}`
    * engine refusal                                    -> `{:error, {:seal_refused, code}}`

  Never raises on the admission path.

  Engine contract (owned by the WasmEngine lane): the engine module exports
  `affi_admit_and_seal/1` taking the canonical JSON binary and returning
  `{:ok, sealed :: binary}` or `{:error, {:seal_refused, code}}`.
  """

  @required_fields ~w(subject_sha authority consequence replay standing)a

  require Logger

  # Engine API resolution: dynamic so this module compiles and stays
  # fail-closed before/without the WasmEngine lane's module on disk.
  @engine_module Smalt.Affidavit.WasmEngine
  @engine_export :affi_admit_and_seal

  @spec admit_and_seal(map(), keyword()) ::
          {:ok, %{sealed: binary(), receipt: map()}}
          | {:error, {:invalid_receipt, atom()}}
          | {:error, {:seal_refused, term()}}
          | {:error, :engine_unavailable}
  def admit_and_seal(receipt, opts \\ [])

  def admit_and_seal(receipt, opts) when is_map(receipt) and is_list(opts) do
    with {:ok, normalized} <- validate(receipt),
         # Lane-608 minimal unblock fix (compile-freeze SLA disclosure):
         # canonical_json/1 builds IO data; the engine export takes a binary.
         canonical = IO.iodata_to_binary(canonical_json(normalized)),
         {:ok, sealed} <- call_engine(canonical, opts) do
      {:ok, %{sealed: sealed, receipt: canonical}}
    end
  end

  def admit_and_seal(_receipt, _opts), do: {:error, {:invalid_receipt, :receipt}}

  @doc """
  JCS-style canonical JSON (RFC 8785 subset sufficient for receipt maps:
  recursively sorted object keys, compact separators, UTF-8 binaries passed
  through). Deterministic: same receipt map, same bytes, every run.
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(term)

  def canonical_json(term) when is_map(term) do
    entries =
      term
      |> Map.to_list()
      # RFC 8785 sorts on UTF-16 code units, ASCENDING; for the ASCII
      # field-name set used here this equals byte/codepoint order.
      # (W17/D1: was :desc — canonical form must sort ascending, else the
      # sealed digest disagrees with any external JCS verifier.)
      |> Enum.sort_by(fn {k, _} -> key_sort(k) end, :asc)
      |> Enum.map(fn {k, v} -> [encode_key(k), ?:, canonical_json(v)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  def canonical_json(term) when is_list(term) do
    [?[, Enum.intersperse(Enum.map(term, &canonical_json/1), ?,), ?]]
  end

  def canonical_json(term) when is_binary(term), do: [?", term, ?"]

  def canonical_json(true), do: "true"
  def canonical_json(false), do: "false"
  def canonical_json(nil), do: "null"

  def canonical_json(n) when is_integer(n), do: Integer.to_string(n)

  def canonical_json(n) when is_float(n),
    do: :erlang.float_to_binary(n, [:compact, decimals: 10])

  defp encode_key(k) when is_atom(k), do: [?", Atom.to_string(k), ?"]
  defp encode_key(k) when is_binary(k), do: [?", k, ?"]

  defp key_sort(k) when is_atom(k), do: Atom.to_string(k)
  defp key_sort(k) when is_binary(k), do: k

  # -- engine call ----------------------------------------------------------

  defp call_engine(canonical, opts) do
    if engine_exported?() do
      call_export(canonical, opts)
    else
      {:error, :engine_unavailable}
    end
  end

  defp engine_exported? do
    match?({:module, @engine_module}, Code.ensure_loaded(@engine_module)) and
      function_exported?(@engine_module, @engine_export, 1)
  end

  # JA-R1 (V3): the fail-closed envelope is unchanged, but the crash/exit/
  # throw is no longer silent — every engine-down refusal that reaches the
  # caller is operator-visible (the module-not-loaded case at call_engine/2
  # stays quiet: it is steady state before the WasmEngine lane lands).
  defp call_export(canonical, opts) do
    canonical
    |> @engine_module.affi_admit_and_seal()
    |> seal_result(opts)
  rescue
    e ->
      Logger.error("affidavit seal: engine crash -> :engine_unavailable (#{Exception.message(e)})")

      {:error, :engine_unavailable}
  catch
    :exit, reason ->
      Logger.error("affidavit seal: engine exit -> :engine_unavailable (#{inspect(reason)})")

      {:error, :engine_unavailable}

    :throw, reason ->
      Logger.error("affidavit seal: engine throw -> :engine_unavailable (#{inspect(reason)})")

      {:error, :engine_unavailable}
  end

  defp seal_result({:ok, sealed}, _opts) when is_binary(sealed), do: {:ok, sealed}

  defp seal_result({:ok, %{} = sealed_map}, opts) do
    # Engine may return a structured sealed envelope; extract per opts.
    key = Keyword.get(opts, :envelope_key, :sealed)

    case Map.fetch(sealed_map, key) do
      {:ok, sealed} when is_binary(sealed) -> {:ok, sealed}
      _ -> {:error, {:seal_refused, :malformed_sealed_output}}
    end
  end

  defp seal_result({:error, {:seal_refused, code}}, _opts), do: {:error, {:seal_refused, code}}

  # Engine-down passthrough: keep the typed :engine_unavailable refusal
  # verbatim instead of re-wrapping it as a seal refusal.
  defp seal_result({:error, :engine_unavailable}, _opts), do: {:error, :engine_unavailable}


  defp seal_result(other, _opts), do: {:error, {:seal_refused, {:malformed_engine_return, other}}}

  # Lane-606 minimal unblock fix (compile-freeze SLA disclosure): validate/1
  # was referenced but not defined by the WasmEngine lane's in-flight file.
  # Minimal presence-check of the five R fields per @required_fields.
  defp validate(receipt) when is_map(receipt) do
    case Enum.find(@required_fields, &is_nil(Map.get(receipt, &1))) do
      nil -> {:ok, receipt}
      field -> {:error, {:invalid_receipt, field}}
    end
  end

end
