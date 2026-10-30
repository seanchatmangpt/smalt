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

  ## Config interaction (GL28-2): `config :smalt, :graphlaw_ex_gate`

  The gate reads `Application.get_env(:smalt, :graphlaw_ex_gate, [])` on every
  gated call. Two flags, both honored HERE (the router's
  `Smalt.Config.graph_law()[:enforcement] == :fail_closed` pre-check at
  arm_gateway/router.ex check_admission_gate/2 is upstream of this module and
  is lane E1's surface — do not change it here):

    - `enabled:` — when explicitly `false` (prod default in config.exs), the
      gate short-circuits to `:ok` (passthrough) BEFORE any validation, so a
      call that slips past the router's enforcement pre-check still honors the
      opt-out. Default when the env key is entirely absent: `true`, so the
      gate stays a usable pure function when nothing is configured (the
      router still decides whether to call at all).
    - `fail_closed:` — `true` (default) is the strict chain below. `false`
      selects the spec §8 fail-open posture (admit-and-seal): a MISSING
      engine digest (no `:engine_digest` opt and no value at
      `opts[:engine_digest_key]` in `:persistent_term`) admits instead of
      refusing. A PRESENT-but-mismatched digest always refuses regardless of
      the flag — fail-open covers unavailability, never drift.

  `max_queue:` is backpressure state for a future queued gate process; the
  pure gate reads it for completeness but it does not affect the decision.
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
    - `:max_request_bytes` — the packet-4 cap (spec §4). Defaults to
      `max_payload/0` (16 MiB, matching `GraphlawEx.ABI.max_request_bytes/0`;
      the constant is mirrored locally rather than called to keep this module
      decidable without the graphlaw_ex dep loaded — the gate must refuse
      even when the engine is down). Oversize answers `:smalt_oversize`.
    - `:engine_digest_key` — the `:persistent_term` key holding the engine
      digest (router passes `:gl_engine_digest`). Consulted only when
      `opts[:engine_digest]` is absent, so an explicit digest always wins.

  Methods match exactly (uppercase `"PUT"`, per spec §3.1).
  """
  @spec gate(String.t(), envelope() | nil, opts()) :: :ok | refused()
  def gate(method, envelope, opts \\ [])

  def gate(method, _envelope, _opts) when method in @ungated_methods, do: :ok

  def gate(method, envelope, opts) when method in @gated_methods,
    do: gate_config(fn cfg -> validate(envelope, opts, cfg) end)

  # Fail-closed: any method outside the two pinned classes is treated as a
  # mutation and must present an admitted envelope (SMALT-METHOD-NA is never
  # emitted, spec §5).
  def gate(_method, envelope, opts), do: gate_config(fn cfg -> validate(envelope, opts, cfg) end)

  # Config read (GL28-2): `config :smalt, :graphlaw_ex_gate` is now live.
  # `enabled: false` is a passthrough decided BEFORE any validation. The
  # default when the env key is absent is enabled — the pure-function courts
  # exercise the chain without config, and prod's opt-out is explicit in
  # config.exs, never silent.
  defp gate_config(cont) do
    cfg = Application.get_env(:smalt, :graphlaw_ex_gate, [])

    if Keyword.get(cfg, :enabled, true) do
      cont.(cfg)
    else
      :ok
    end
  end

  ## ── validation chain (first failure wins) ──────────────────────────────

  # Order pinned by the shared contract: envelope keys -> payload ->
  # engine_digest -> receipt_blake3 well-formedness -> replay.
  @spec validate(envelope() | nil, opts(), keyword()) :: :ok | refused()
  defp validate(envelope, opts, cfg) do
    with :ok <- envelope_check(envelope),
         :ok <- payload_check(envelope, opts),
         :ok <- engine_check(envelope, opts, cfg),
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

      byte_size(payload) > max_request_bytes(opts) ->
        {:refused, :smalt_oversize,
         %{payload_bytes: byte_size(payload), max_payload: max_request_bytes(opts)}}

      true ->
        :ok
    end
  end

  # Step 4 — engine identity. Resolution order: explicit `opts[:engine_digest]`
  # wins; else `:persistent_term.get(opts[:engine_digest_key], nil)`. A nil
  # resolved digest fails closed (default) or admits (fail-open posture,
  # `fail_closed: false` in config — unavailability only, never drift).
  @spec engine_check(envelope(), opts(), keyword()) :: :ok | refused()
  defp engine_check(envelope, opts, cfg) do
    expected =
      case opts[:engine_digest] do
        nil -> persistent_digest(opts[:engine_digest_key])
        digest -> digest
      end

    actual = Map.fetch!(envelope, :engine_digest)

    cond do
      expected == actual ->
        :ok

      is_nil(expected) and fail_closed?(cfg) ->
        {:refused, :smalt_engine_drift, %{expected: expected, actual: actual}}

      is_nil(expected) ->
        # Fail-open posture (spec §8 admit-and-seal): digest unavailable,
        # not drifted. A mismatched PRESENT digest never reaches this arm.
        :ok

      true ->
        {:refused, :smalt_engine_drift, %{expected: expected, actual: actual}}
    end
  end

  defp persistent_digest(nil), do: nil

  defp persistent_digest(key) do
    :persistent_term.get(key, nil)
  rescue
    _ -> nil
  end

  defp fail_closed?(cfg), do: Keyword.get(cfg, :fail_closed, true)

  # `max_request_bytes` opt (router gate_opts/1) overrides the module default;
  # a non-positive-integer opt falls back to the 16 MiB packet-4 cap.
  defp max_request_bytes(opts) do
    case opts[:max_request_bytes] do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_payload
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
