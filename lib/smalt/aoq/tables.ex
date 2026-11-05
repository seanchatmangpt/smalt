defmodule Smalt.Aoq.Tables do
  @moduledoc """
  AOQ `:persistent_term` tables (spec §5,
  `docs/jira/v26.11.5/aq-architecture-spec.md`).

  Three single-key tables, boot-write / hot-read:

  - `{:aoq, :frame_types}` — frame-type byte → `{module, function}`
    handler map, written once at boot from the static frame-type
    registry (compile-time module attribute).
  - `{:aoq, :epochs}` — epoch id → `{key material reference, start
    offset}`, append-only per epoch (old epochs retained for late
    frames); written at boot and only on operator-driven rotation.
  - `{:aoq, :arrow_schemas}` — schema id → compiled Arrow schema term
    (in v1 a plain term; the NIF resource form lands with NifHolder),
    written at boot from the schema bundle.

  A table whose key never changes after boot costs one GC-scan-free
  read forever. `boot/1` writes all three keys and then seals them:
  every non-boot mutation path (frame-type registration, epoch
  append, schema put) raises a typed error once the seal is present.
  The only lawful post-boot update is a full `boot/1` re-derive from
  the boot source (which pays the documented global GC scan cost).
  """

  @frame_types %{
    # 0x01 data frame, 0x02 control/ack, 0x03 epoch-rotate, 0x7F reserved
    0x01 => {Smalt.Aoq.Frame, :handle_data},
    0x02 => {Smalt.Aoq.Frame, :handle_ack},
    0x03 => {Smalt.Aoq.Frame, :handle_epoch_rotate},
    0x7F => {Smalt.Aoq.Frame, :handle_reserved}
  }

  @epochs %{}

  @arrow_schemas %{}

  @typedoc "Refusal reason carried in the raised error message payload."
  @type sealed_error :: {:aoq_tables_sealed, key :: atom()}

  @doc """
  Writes all three tables from the boot source and seals them.
  Idempotent re-derivation: a second `boot/1` legally overwrites the
  whole map per key (the only lawful mutation class). Options
  override the compile-time registries (test/bundle injection):
  `:frame_types`, `:epochs`, `:arrow_schemas` (maps).
  """
  @spec boot(keyword()) :: :ok
  def boot(opts \\ []) do
    :persistent_term.put({:aoq, :frame_types}, Keyword.get(opts, :frame_types, @frame_types))
    :persistent_term.put({:aoq, :epochs}, Keyword.get(opts, :epochs, @epochs))
    :persistent_term.put({:aoq, :arrow_schemas}, Keyword.get(opts, :arrow_schemas, @arrow_schemas))
    :persistent_term.put({:aoq, :sealed}, System.unique_integer([:monotonic]))
    :ok
  end

  @doc """
  Compile-time Arrow registry fallback (LANE-52, additive): what
  `{:aoq, :arrow_schemas}` holds when the bundle refuses at boot or
  `boot/1` runs with no `:arrow_schemas` opt. Exposed so
  `Smalt.Aoq.Arrow.Boot` can return the SAME map on a loud fallback
  instead of re-deriving its own empty map (one source of truth).
  """
  @spec fallback_arrow_schemas() :: %{term() => term()}
  def fallback_arrow_schemas, do: @arrow_schemas

  @doc "True when the tables have been booted (seal key present)."
  @spec sealed?() :: boolean()
  def sealed? do
    :persistent_term.get({:aoq, :sealed}, nil) != nil
  end

  @doc "Hot read: frame-type byte → `{module, function}` handler map."
  @spec frame_types() :: %{non_neg_integer() => {module(), atom()}}
  def frame_types do
    fetch(:frame_types)
  end

  @doc "Handler for one frame-type byte (raises if the table is unbooted)."
  @spec frame_handler(non_neg_integer()) :: {module(), atom()}
  def frame_handler(type) do
    Map.fetch!(frame_types(), type)
  end

  @doc "Hot read: epoch id → `{key material reference, start offset}` map."
  @spec epochs() :: %{non_neg_integer() => term()}
  def epochs do
    fetch(:epochs)
  end

  @doc "Hot read: schema id → compiled Arrow schema term."
  @spec arrow_schemas() :: %{term() => term()}
  def arrow_schemas do
    fetch(:arrow_schemas)
  end

  @doc """
  Appends an epoch (`{:aoq, :epochs}` is append-only per epoch).
  Refuses with `{:aoq_tables_sealed, :epochs}` after boot — rotation
  is operator-driven and re-derives via a full boot, not this path.
  """
  @spec append_epoch(non_neg_integer(), term()) :: no_return()
  def append_epoch(epoch_id, value) do
    guarded_put(:epochs, fn m -> Map.put(m, epoch_id, value) end)
  end

  @doc "Registers a frame-type handler. Refuses after boot."
  @spec register_frame_type(non_neg_integer(), {module(), atom()}) :: no_return()
  def register_frame_type(type, handler) do
    guarded_put(:frame_types, fn m -> Map.put(m, type, handler) end)
  end

  @doc "Puts a compiled Arrow schema. Refuses after boot."
  @spec put_arrow_schema(term(), term()) :: no_return()
  def put_arrow_schema(schema_id, schema) do
    guarded_put(:arrow_schemas, fn m -> Map.put(m, schema_id, schema) end)
  end

  @doc """
  The narrow lawful post-boot epoch-rotation path (spec §5: any future
  mutation of these tables must re-derive and put the whole map).

  Appends `epoch_id` to the `{:aoq, :epochs}` map and puts the WHOLE
  map in one `:persistent_term.put` — never an incremental write.
  The registry is append-only per epoch: a `epoch_id` not strictly
  greater than every existing epoch id is a regression and is refused
  (old epochs retained for late frames, so overwrite is impossible).

  Returns typed results (never raises):

  - `:ok` — epoch appended, whole map re-put, seal untouched
  - `{:error, :tables_unbooted}` — seal absent (pre-boot rotate)
  - `{:error, {:epoch_regression, epoch_id, max_existing}}`
  """
  @spec rotate_epoch(non_neg_integer(), term()) ::
          :ok | {:error, :tables_unbooted | {:epoch_regression, non_neg_integer(), non_neg_integer()}}
  def rotate_epoch(epoch_id, value) do
    case :persistent_term.get({:aoq, :sealed}, nil) do
      nil ->
        {:error, :tables_unbooted}

      _seal ->
        epochs = :persistent_term.get({:aoq, :epochs})

        max_existing =
          epochs |> Map.keys() |> case do
            [] -> nil
            keys -> Enum.max(keys)
          end

        if max_existing != nil and epoch_id <= max_existing do
          {:error, {:epoch_regression, epoch_id, max_existing}}
        else
          # Lawful mutation class: re-derive the whole map, one put.
          :persistent_term.put({:aoq, :epochs}, Map.put(epochs, epoch_id, value))
          :ok
        end
    end
  end

  # ── internals ──────────────────────────────────────────────────────

  defp fetch(name) do
    :persistent_term.get({:aoq, name})
  end

  defp guarded_put(_name, _fun) do
    case :persistent_term.get({:aoq, :sealed}, nil) do
      nil ->
        # Unbooted: incremental mutation before boot would create a
        # partial table; the only lawful path is a full boot.
        raise ArgumentError, "AOQ tables not booted; call Smalt.Aoq.Tables.boot/1 first"

      _seal ->
        # Post-boot mutation refusal (raise, never silently write):
        # the only lawful update is a full re-derivation via boot/1.
        raise ArgumentError,
              "AOQ table sealed at boot (post-boot write refused); " <>
                "re-derive via Smalt.Aoq.Tables.boot/1"
    end
  end
end
