defmodule Smalt.GraphlawEx.AdmissionGate do
  @moduledoc """
  GL28-2 — Smalt ingress commit gate (pure decision logic).

  A mutation (PUT/POST/DELETE) may commit only on an in-hand
  `{:admitted_mutation, payload_bytes, receipt_blake3, engine_digest,
  ocel_frame}` envelope minted by graphlaw_ex. The proof of admission is the
  receipt, not a boolean (GL28-2-SMALT-WIRE-SPEC §1-§3).

  The gate is a pure function of `(method, envelope, opts)`: zero state
  mutation on any refusal — no ETS write, no `:persistent_term` write, no
  counter bump. Recording the receipt into the ledger is the caller's
  post-commit step (spec §3.5), never this module's.

  Validation chain (ordered, first failure wins, spec §3):

    1. Method filter — GET/HEAD/OPTIONS pass ungated; PUT/POST/DELETE are
       gated; any other method is gated too (fail-closed: an unknown method
       without an admitted envelope surfaces `:smalt_no_receipt`).
    2. Envelope — the map form of the 5-tuple; all five keys must be present
       with non-nil, non-false values, else `:smalt_no_receipt`.
    3. Payload — a non-binary `payload_bytes` is `:smalt_payload_mismatch`;
       then `opts[:body]` (the raw request body), when supplied, must equal
       `payload_bytes` byte-exactly (no Smalt-side re-canonicalization, spec
       §2.1), else `:smalt_payload_mismatch`; then `byte_size(payload_bytes)
       > max_payload/0` (16 MiB packet-4 cap, spec §4) is `:smalt_oversize`.
    4. Engine — `envelope.engine_digest` must equal `opts[:engine_digest]`
       (the caller's view of the `:gl_engine_digest` `:persistent_term`),
       else `:smalt_engine_drift` (fail-closed on a nil digest).
    5. Receipt — `receipt_blake3` must be 64 lowercase hex chars, else
       `:smalt_receipt_invalid`.
    6. Replay — when `opts[:seen_receipts]` (a MapSet) already contains the
       receipt, `:smalt_receipt_replay_fail`; an absent ledger skips the
       check (shallow mode, spec §7 Q2).

  Refusal codes are append-only (spec §5). `SMALT-METHOD-NA` is deliberately
  absent: the GET-class is ungated, not refused.
  """

  @envelope_keys ~w(admitted_mutation payload_bytes receipt_blake3 engine_digest ocel_frame)a
  @max_payload 16 * 1024 * 1024

  @gated_methods ~w(PUT POST DELETE)
  @ungated_methods ~w(GET HEAD OPTIONS)

  @hex64_source "^[0-9a-f]{64}$"
  @hex64_regex Regex.compile!(@hex64_source)
  @type refused :: {:refused, code :: atom(), details :: map()}
  @type envelope :: map()
  @type opts :: keyword()

  @doc """
  Current packet-4 payload cap (mirrors `GraphlawEx.ABI.max_request_bytes/0`,
  16 MiB). Exposed so the oversize court can assert the boundary without
  duplicating the constant.
  """
  @spec max_payload() :: pos_integer()
  def max_payload, do: @max_payload

  @doc """
  The five admission-envelope keys, in spec §2 order.
  """
  @spec envelope_keys() :: [atom(), ...]
  def envelope_keys, do: @envelope_keys

  @doc """
  Gate one ingress request.

  Returns `:ok` when the request may commit, or `{:refused, code, details}`
  from the append-only code set (`:smalt_no_receipt`, `:smalt_payload_mismatch`,
  `:smalt_receipt_invalid`, `:smalt_engine_drift`,
  `:smalt_receipt_replay_fail`, `:smalt_oversize`).

  Opts:

    - `:body` — the raw request body. When supplied (non-nil), the envelope's
      `payload_bytes` must equal it byte-exactly.
    - `:engine_digest` — the current engine digest (Smalt's view of
      graphlaw_ex's `:gl_engine_digest` `:persistent_term`). `nil` (not wired
      yet) fails closed as `:smalt_engine_drift`.
    - `:seen_receipts` — the replay ledger, a MapSet of receipt hashes. The
      gate READS it, never writes it; the caller records post-commit. Absent
      ledger skips the replay check.

  Methods match exactly (uppercase `"PUT"`, per spec §3.1).
  """
  @spec gate(String.t(), envelope() | nil, opts()) :: :ok | refused()
  def gate(method, envelope, opts \\ [])

  def gate(method, _envelope, _opts) when method in @ungated_methods, do: :ok

  def gate(method, envelope, opts) when method in @gated_methods,
    do: validate(envelope, opts)

  # Fail-closed: any method outside the two pinned classes is treated as a
  # mutation and must present an admitted envelope (SMALT-METHOD-NA is never
  # emitted, spec §5).
  def gate(_method, envelope, opts), do: validate(envelope, opts)

  ## ── validation chain (first failure wins) ──────────────────────────────

  # Order pinned by the shared contract: envelope keys -> payload ->
  # engine_digest -> receipt_blake3 well-formedness -> replay.
  @spec validate(envelope() | nil, opts()) :: :ok | refused()
  defp validate(envelope, opts) do
    with :ok <- envelope_check(envelope),
         :ok <- payload_check(envelope, opts),
         :ok <- engine_check(envelope, opts),
         :ok <- receipt_check(envelope),
         :ok <- replay_check(envelope, opts) do
      :ok
    end
  end

  # Step 2 — envelope presence and shape. The map form of the 5-tuple must
  # carry every key with a non-nil, non-false value; `admitted_mutation: false`
  # is not an admitted envelope.
  @spec envelope_check(envelope() | nil) :: :ok | refused()
  defp envelope_check(envelope) when is_map(envelope) do
    missing = for key <- @envelope_keys, blank?(Map.get(envelope, key)), do: key

    case missing do
      [] -> :ok
      missing -> {:refused, :smalt_no_receipt, %{missing_keys: missing}}
    end
  end

  defp envelope_check(nil),
    do: {:refused, :smalt_no_receipt, %{envelope: nil}}

  defp envelope_check(other),
    do: {:refused, :smalt_no_receipt, %{envelope_class: value_class(other)}}

  # Step 3 — payload: class check, then byte-exact equality with the raw
  # request body (no re-canonicalization), then the packet-4 size cap.
  @spec payload_check(envelope(), opts()) :: :ok | refused()
  defp payload_check(envelope, opts) do
    payload = Map.fetch!(envelope, :payload_bytes)

    cond do
      not is_binary(payload) ->
        {:refused, :smalt_payload_mismatch,
         %{reason: :payload_not_binary, payload_class: value_class(payload)}}

      body_present?(opts) and payload != opts[:body] ->
        {:refused, :smalt_payload_mismatch,
         %{payload_bytes: byte_size(payload), body: byte_size(opts[:body])}}

      byte_size(payload) > @max_payload ->
        {:refused, :smalt_oversize,
         %{payload_bytes: byte_size(payload), max_payload: @max_payload}}

      true ->
        :ok
    end
  end

  # Step 4 — engine identity. A nil `opts[:engine_digest]` (digest not yet
  # wired) fails closed: a receipt minted by an unknown engine never commits.
  @spec engine_check(envelope(), opts()) :: :ok | refused()
  defp engine_check(envelope, opts) do
    expected = opts[:engine_digest]
    actual = Map.fetch!(envelope, :engine_digest)

    if expected == actual do
      :ok
    else
      {:refused, :smalt_engine_drift, %{expected: expected, actual: actual}}
    end
  end

  # Step 5 — receipt well-formedness: 64 lowercase hex chars (BLAKE3 hex
  # encoding of the canonical receipt document, spec §2.2). Deliberately
  # local and pure — the gate stays decidable without the engine up (spec §2.4).
  @spec receipt_check(envelope()) :: :ok | refused()
  defp receipt_check(envelope) do
    receipt = Map.fetch!(envelope, :receipt_blake3)

    if is_binary(receipt) and Regex.match?(hex64(), receipt) do
      :ok
    else
      {:refused, :smalt_receipt_invalid, %{receipt_blake3_class: value_class(receipt)}}
    end
  end

  # Step 6 — replay: the receipt must be fresh against the caller's ledger.
  # Absent ledger = shallow mode, check skipped. A ledger of the wrong type
  # fails loud (FunctionClauseError) rather than coercing silently.
  @spec replay_check(envelope(), opts()) :: :ok | refused()
  defp replay_check(envelope, opts) do
    receipt = Map.fetch!(envelope, :receipt_blake3)

    case opts[:seen_receipts] do
      nil ->
        :ok

      %MapSet{} = seen ->
        if MapSet.member?(seen, receipt) do
          {:refused, :smalt_receipt_replay_fail, %{receipt_blake3: receipt}}
        else
          :ok
        end
    end
  end

  ## ── internal helpers ───────────────────────────────────────────────────

  defp body_present?(opts) do
    Keyword.has_key?(opts, :body) and not is_nil(opts[:body])
  end

  # Compiled once at module load. Held via Regex.compile!/1 (not a ~r sigil
  # attribute) so the read types as %Regex{} for the compiler — a sigil in a
  # module attribute types as binary and trips warnings-as-errors on
  # Regex.match?/2.
  defp hex64, do: @hex64_regex

  defp blank?(nil), do: true
  defp blank?(false), do: true
  defp blank?(_), do: false

  defp value_class(nil), do: :nil
  defp value_class(value) when is_binary(value), do: :binary
  defp value_class(value) when is_integer(value), do: :integer
  defp value_class(value) when is_float(value), do: :float
  defp value_class(value) when is_atom(value), do: :atom
  defp value_class(value) when is_map(value), do: :map
  defp value_class(value) when is_list(value), do: :list
  defp value_class(value) when is_tuple(value), do: :tuple
end
