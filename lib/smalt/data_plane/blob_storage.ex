defmodule Smalt.DataPlane.BlobStorage do
  @moduledoc """
  Pure Elixir Azure Immutable Blob Storage REST engine (`Microsoft.Storage/storageAccounts`).
  Supports container creation, block blob PUT/GET/DELETE, ETag generation, If-Match
  preconditions, legal hold and immutability policy (WORM), and XML blob listing.

  ## WORM arm convention

  Every WORM check resolves to one of three arms by verb: `create` is
  hold-only (immutability protects existing data, not namespace growth —
  R5); `overwrite` refuses when a legal hold, a locked immutability policy,
  or an unexpired retention is present; `delete` requires clearing the
  delete clause. Metadata mutation rides the `overwrite` arm.
  Create-or-overwrite verbs (e.g. Put Block List) resolve the arm from
  blob existence — never hardcode the arm at the call site.
  """
  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.Store

  @policy_table :smalt_blob_policy

  # D127 (ARM teardown cascade): deleting a storageAccount (directly or via
  # RG delete) must not orphan data-plane rows. Blob tables key rows as
  # "account/container" and "account/container/blob", so an account-prefix
  # sweep ("acct/") across every blob table removes the account's whole
  # data-plane footprint. Lazily-created tables (:smalt_blob_blocks,
  # :smalt_blob_snapshots) may not be booted — guard with :ets.info. The
  # per-container DELETE route stays a product-faithful gap (D127 scopes the
  # cascade to account teardown, not container teardown).
  @doc false
  @spec drop_account_data(String.t()) :: :ok
  def drop_account_data(account) when is_binary(account) do
    base = String.downcase("#{account}/")

    tables = [
      :smalt_blob_containers,
      :smalt_blobs,
      :smalt_blob_policy,
      :smalt_blob_blocks,
      :smalt_blob_snapshots
    ]

    for table <- tables,
        :ets.info(table) != :undefined,
        key <- Store.prefix_keys(table, base) do
      Store.delete(table, key)
    end

    :ok
  end

  def create_container(account, container, opts \\ %{}) do
    with :ok <- check_container_name(container) do
      do_create_container(account, container, opts)
    end
  end

  @doc """
  Deletes a blob container and all its contained blobs, blocks, and snapshots.
  Respects WORM legal hold and immutability policy (409 ContainerLocked).
  Returns `{:ok, 202, headers, nil}` on success, or `{:error, status, code, msg}`.
  """
  def delete_container(account, container, opts \\ []) do
    container_key = "#{account}/#{container}"
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         :ok <- check_worm(container_meta, now),
         :ok <- check_lease_on_delete(container_meta, opts, now) do
      base = "#{account}/#{container}/"

      # Cascade deletion of blobs, policies, blocks, snapshots under container
      tables = [
        :smalt_blobs,
        :smalt_blob_policy,
        :smalt_blob_blocks,
        :smalt_blob_snapshots
      ]

      for table <- tables,
          :ets.info(table) != :undefined,
          key <- Store.prefix_keys(table, base) do
        Store.delete(table, key)
      end

      # Delete container policy if any
      if :ets.info(:smalt_blob_policy) != :undefined do
        Store.delete(:smalt_blob_policy, container_key)
      end

      # Delete container record
      Store.delete(:smalt_blob_containers, container_key)

      {:ok, 202, %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02"}, nil}
    else
      :error ->
        {:error, 404, "ContainerNotFound", "The specified container does not exist."}

      {:error, {:worm, reason}} ->
        {:error, 409, "ContainerLocked", worm_message_reason(reason)}

      # KD-108: active lease blocks Delete Container (409 ContainerLeased)
      # unless the request carries the matching x-ms-lease-id.
      {:error, 409, "ContainerLeased", msg} ->
        {:error, 409, "ContainerLeased", msg}
    end
  end

  # Azure parity (cycle-25, Put Container): container names are 3-63 bytes,
  # lowercase letters/digits/dashes, starting and ending alphanumeric. Real
  # Azure answers 400 InvalidResourceName; smalt accepted anything and the
  # duplicate-create silently replaced records (WORM clock reset).
  @container_name_re ~r/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/

  defp check_container_name(name) when is_binary(name) do
    if name == "" or byte_size(name) > 63 or not Regex.match?(@container_name_re, name) do
      {:error, 400, "InvalidResourceName",
       "The specified container name is invalid (3-63 bytes, lowercase letters, digits and dashes, starting and ending alphanumeric)."}
    else
      :ok
    end
  end

  defp check_container_name(_),
    do: {:error, 400, "InvalidResourceName", "The specified container name is invalid."}

  # Azure parity (cycle-25): Put Container on an existing container is 409
  # ContainerAlreadyExists — previously any duplicate create silently
  # REPLACED the record (created_at/WORM clock reset, flag flip-flop).
  defp do_create_container(account, container, opts) do
    key = "#{account}/#{container}"

    with :error <- Smalt.Store.get(:smalt_blob_containers, key) do
      created_at = Map.get(opts, "created_at_ms") || System.os_time(:millisecond)

      record = %{
        "account" => account,
        "container" => container,
        "immutable" => Map.get(opts, "immutable", true),
        "retention_days" => Map.get(opts, "retention_days", 1095),
        "created_at" => created_at,
        "created" => DateTime.from_unix!(created_at, :millisecond) |> DateTime.to_iso8601()
      }

      Store.put(:smalt_blob_containers, key, record)
      {:ok, record}
    else
      {:ok, _existing} ->
        {:error, 409, "ContainerAlreadyExists", "The specified container already exists."}
    end
  end

  @doc """
  Validate List Blobs `maxresults` (Azure grammar: 1-5000; non-positive or
  non-integer values are 400 InvalidQueryParameterValue, never silently coerced
  to the default page size).
  """
  def check_maxresults(nil), do: :ok

  def check_maxresults(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> :ok
      _ -> maxresults_error()
    end
  end

  def check_maxresults(n) when is_integer(n) and n > 0, do: :ok
  def check_maxresults(_), do: maxresults_error()

  defp maxresults_error,
    do:
      {:error, 400, "InvalidQueryParameterValue",
       "Value for maxresults is invalid (must be a positive integer)."}

  @doc """
  Time-aware policy evaluation for a container. `:now_ms` is injected
  (defaults to `System.os_time(:millisecond)`).

  Returns `{:ok, %{"locked" => bool, "legal_hold" => bool, "expired" => bool,
  "expires_at" => ms | nil}}` or `{:error, :container_not_found}`. When
  `now > created_at + retention_days` the container's immutability policy has
  expired and the container unlocks (overwrite/delete permitted). Legal holds
  NEVER auto-expire. Legacy containers without `created_at` are conservatively
  reported as not-yet-expired.
  """
  def policy_state(account, container, opts \\ []) do
    now = now_ms(opts)
    container_key = container_key(account, container)

    with {:ok, meta} <- Store.get(:smalt_blob_containers, container_key) do
      policy = fetch_policy(meta)
      expires_at = retention_end_ms(meta)

      {:ok,
       %{
         "locked" => locked_policy?(policy),
         "legal_hold" => legal_hold?(policy),
         "expired" => expired?(meta, now),
         "expires_at" => expires_at
       }}
    else
      :error -> {:error, :container_not_found}
    end
  end

  # Documented C4 fence: a single PUT carries at most 1 MiB of blob content.
  # Real Azure enforces a per-request size cap with 413 RequestBodyTooLarge;
  # smalt's fence is 1,048,576 bytes (the 8,000,000-byte egress_router
  # read_body cap stays as the transport-level backstop).
  @max_put_bytes 1_048_576

  @doc """
  PUT blob. Hardened: If-Match precondition (412 on mismatch), WORM refusal
  extended to legal hold and locked immutability policy (409 `ContainerLocked`),
  and a 1 MiB per-PUT content cap (`{:error, :too_large, msg}` — the router maps
  it to 413 `RequestBodyTooLarge`).
  """
  def put_blob(account, container, blob_name, content, headers \\ %{}, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with :ok <- check_blob_name(blob_name),
         {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         :ok <- check_content(content),
         :ok <- check_put_size(content),
         :ok <- check_metadata_names(headers) do
      case Store.get(:smalt_blobs, blob_key) do
        {:ok, existing} ->
          cond do
            worm_blocked?(container_meta, "overwrite", now) ->
              {:error, :worm_locked, worm_message(container_meta, now)}

            mismatched_if_match?(headers, existing["etag"]) ->
              {:error, :precondition_failed, precondition_message()}

            # Azure parity (cycle-21): If-None-Match: * refuses overwrite of
            # an existing blob (412) — previously silently ignored, so a
            # conditional-create raced through as an unconditional overwrite.
            if_none_match_star?(headers) ->
              {:error, :precondition_failed, precondition_message()}

            # AZB-06: the If-Match replace runs as a Store CAS
            # (compare_and_swap/4 inside the Store GenServer), so N concurrent
            # replaces carrying the same If-Match etag yield EXACTLY one
            # winner (200/201) and N-1 precondition losers (412) — the old
            # read-then-write TOCTOU could admit multiple winners.
            true ->
              cas_replace(account, container, blob_name, content, headers, existing)
          end

        :error ->
          cond do
            # Azure parity (R5: audit A1 defect, create-under-hold): a legal
            # hold blocks NEW-blob creation with 409 ContainerLocked, same
            # as overwrite. Previously the create arm skipped the WORM check
            # entirely. Time-based immutability alone does not block create
            # (real Azure permits new-blob writes into retention containers),
            # so the create arm consults the hold-scoped predicate clause.
            worm_blocked?(container_meta, "create", now) ->
              {:error, :worm_locked, worm_message(container_meta, now)}

            # Azure parity (cycle-21): If-Match on a NON-EXISTENT blob is
            # 412 (a precondition on a resource that does not exist fails).
            # Previously the create path skipped all preconditions, so
            # If-Match: * created unconditionally.
            ConditionalHeaders.header(headers, "if-match") != nil ->
              {:error, :precondition_failed, precondition_message()}

            true ->
              store_blob(account, container, blob_name, content, headers)
          end
      end
    else
      :error ->
        {:error, :container_not_found}

      {:error, :too_large, msg} ->
        {:error, :too_large, msg}

      {:error, 400, _code, _msg} = invalid ->
        invalid
    end
  end

  # Azure parity (Put Blob): real Azure rejects control characters in blob
  # names at PUT with 400 InvalidResourceName, and names are bounded
  # (1,024 characters per the naming reference). smalt accepted any bytes
  # and only sanitized at listing emission (cycle-11).
  @max_blob_name_bytes 1_024

  defp check_blob_name(name) when is_binary(name) do
    cond do
      String.match?(name, ~r/[\x00-\x1F\x7F]/) ->
        {:error, 400, "InvalidResourceName",
         "The specified blob name is invalid (control characters are not permitted)."}

      # Zero-visible class (lens-5 routing): whitespace-only and
      # invisible-format-only (Unicode Cf / BOM) names are unreadable custody
      # keys that collide visually in blob.list — same fence vocabulary as
      # Smalt.Projection.Identity.valid?/1 (shared read-side fence).
      name == "" or byte_size(name) > @max_blob_name_bytes or
          not Smalt.Projection.Identity.valid?(name) ->
        {:error, 400, "InvalidResourceName",
         "The specified blob name is invalid (must be 1 to 1024 visible bytes)."}

      true ->
        :ok
    end
  end

  defp check_blob_name(_),
    do: {:error, 400, "InvalidResourceName", "The specified blob name is invalid."}

  # Azure parity (Put Blob / Put Metadata): user metadata names must be valid
  # C# identifiers; violations answer 400 InvalidMetadata, never a stored row.
  @meta_name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp check_metadata_names(headers) when is_map(headers) do
    bad =
      Enum.find(headers, fn {k, v} ->
        case k do
          "x-ms-meta-" <> name ->
            not Regex.match?(@meta_name_re, name) or
              not (is_binary(v) and not Regex.match?(~r/[\x00-\x1F\x7F]/, v))

          _ ->
            false
        end
      end)

    case bad do
      nil ->
        :ok

      {k, _} ->
        {:error, 400, "InvalidMetadata",
         "Invalid metadata name (must be a valid C# identifier) or value (must be a control-character-free binary): #{k}."}
    end
  end

  defp check_metadata_names(_), do: :ok

  # Azure parity: container existence (404) outranks request size (413).
  defp check_put_size(content) do
    if byte_size(content) > @max_put_bytes do
      {:error, :too_large, too_large_message()}
    else
      :ok
    end
  end

  defp too_large_message,
    do: "A single request exceeds the 1,048,576-byte limit (RequestBodyTooLarge)."

  # ---------------------------------------------------------------------------
  # Block staging and commit (Put Block / Put Block List / Get Block List).
  # X-1 (v26.10.14): comp=blocklist previously fell into the generic Put Blob
  # arm, storing the request XML as the blob body — a 7.5 MiB staged payload
  # committed as a 390-byte XML doc. Staged blocks now persist keyed
  # account/container/blob/block-id; commit concatenates them in blocklist
  # order into the blob body.
  # ---------------------------------------------------------------------------

  @block_table :smalt_blob_blocks

  @doc false
  def ensure_block_table do
    if :ets.info(@block_table) == :undefined do
      :ets.new(@block_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Put Block (PUT ?comp=block&blockid=...): stages `content` under
  account/container/blob/block-id. Returns `{:ok, 201, headers}` or
  `{:error, status, code, msg}`. Per-block content rides the same 1 MiB
  per-request fence as Put Blob.
  """
  # KD-COVERS: KD-52 (blocklist stage/commit/get — X-1)
  def stage_block(account, container, blob_name, block_id, content, _headers \\ %{}, opts \\ []) do
    ensure_block_table()

    with :ok <- check_blob_name(blob_name),
         {:ok, _container_meta} <-
           Store.get(:smalt_blob_containers, container_key(account, container)),
         :ok <- check_content(content),
         :ok <- check_put_size(content),
         :ok <- check_block_id(block_id) do
      Store.put(@block_table, block_key(account, container, blob_name, block_id), %{
        "block_id" => block_id,
        "content" => content,
        "size" => byte_size(content),
        "staged_at" => now_ms(opts)
      })

      {:ok, 201, %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02"}}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, 400, _code, _msg} = invalid -> invalid
      {:error, :too_large, msg} -> {:error, 413, "RequestBodyTooLarge", msg}
    end
  end

  # Azure grammar: a block id is 1-64 bytes; when un-encoded it must be a
  # valid base64 string. Fence the length (the common failure — an empty or
  # oversize id — with 400 InvalidQueryParameterValue, Azure's wire shape).
  defp check_block_id(block_id) when is_binary(block_id) do
    if block_id == "" or byte_size(block_id) > 64 do
      {:error, 400, "InvalidQueryParameterValue", "The blockid must be between 1 and 64 bytes."}
    else
      :ok
    end
  end

  defp check_block_id(_),
    do: {:error, 400, "InvalidQueryParameterValue", "The blockid must be a string."}

  defp block_key(account, container, blob_name, block_id) do
    # NUL separator: blob names may contain "/" (slash-blobs are legal), so a
    # "/" join could collide with blob names ending in /<blockid>.
    :erlang.iolist_to_binary([
      "#{account}/#{container}/#{blob_name}",
      0,
      block_id
    ])
  end

  # Block-list entry: {"latest" | "committed" | "uncommitted", block_id}.
  @doc """
  Put Block List (PUT ?comp=blocklist): parses the request XML, concatenates
  the referenced staged blocks in blocklist order, and commits the result as
  the blob body. Honors WORM and If-Match/If-None-Match preconditions (same
  semantics as Put Blob overwrite). Staged blocks are retained so a later
  list can re-reference them as committed.
  """
  def commit_block_list(account, container, blob_name, refs, headers \\ %{}, opts \\ []) do
    ensure_block_table()
    container_k = container_key(account, container)
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with :ok <- check_blob_name(blob_name),
         {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_k),
         {:ok, blocks} <- resolve_refs(refs, account, container, blob_name) do
      cond do
        # SHIM-COURT / KD-COVERS: KD-52 — existence-scoped WORM arm (parity
        # with put_blob): a legal hold blocks BOTH overwrite and create, but
        # time-retention only blocks overwrite of an existing blob (a new
        # blob commit under an unlocked/retention container is 201, R5).
        worm_blocked?(
          container_meta,
          if(existing_blob?(blob_key), do: "overwrite", else: "create"),
          now
        ) ->
          {:error, :worm_locked, worm_message(container_meta, now)}

        mismatched_if_match?(headers, committed_etag(blob_key)) ->
          {:error, :precondition_failed, precondition_message()}

        if_none_match_star?(headers) and existing_blob?(blob_key) ->
          {:error, :precondition_failed, precondition_message()}

        true ->
          content = blocks |> Enum.map(& &1["content"]) |> IO.iodata_to_binary()

          # Azure Put Block List honors x-ms-blob-content-* on the commit
          # request; fold them into the stored header map as canonical keys.
          headers =
            Enum.reduce(
              ["content-type", "content-encoding", "content-language"],
              headers,
              fn wire, acc ->
                case header_value(headers, "x-ms-blob-" <> wire) do
                  nil -> acc
                  value -> Map.put(acc, wire, value)
                end
              end
            )

          {:ok, blob} = store_blob(account, container, blob_name, content, headers)

          blob =
            Map.put(
              blob,
              "blocks",
              Enum.map(blocks, fn b ->
                %{"block_id" => b["block_id"], "size" => b["size"]}
              end)
            )

          Store.put(:smalt_blobs, blob_key, blob)

          {:ok, 201,
           %{
             "etag" => blob["etag"],
             "x-ms-request-id" => request_id(),
             "x-ms-version" => "2021-12-02"
           }}
      end
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, 400, _code, _msg} = invalid -> invalid
      {:error, :worm_locked, msg} -> {:error, :worm_locked, msg}
      {:error, :precondition_failed, msg} -> {:error, :precondition_failed, msg}
    end
  end

  # Resolve block-list references to staged block records in order. Azure
  # answers 400 InvalidBlockList when a referenced block was never staged.
  defp resolve_refs(refs, account, container, blob_name) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn {_kind, block_id}, {:ok, acc} ->
      block = fetch_block(account, container, blob_name, block_id)

      case block do
        nil ->
          {:halt,
           {:error, 400, "InvalidBlockList",
            "The specified block list is invalid (block not found: #{block_id})."}}

        b ->
          {:cont, {:ok, [b | acc]}}
      end
    end)
    |> case do
      {:ok, blocks} -> {:ok, Enum.reverse(blocks)}
      error -> error
    end
  end

  defp resolve_refs(_, _, _, _),
    do: {:error, 400, "InvalidXmlDocument", "The block list body is not valid XML."}

  defp fetch_block(account, container, blob_name, block_id) do
    ensure_block_table()

    case Store.get(@block_table, block_key(account, container, blob_name, block_id)) do
      {:ok, block} -> block
      :error -> nil
    end
  end

  defp existing_blob?(blob_key) do
    match?({:ok, _}, Store.get(:smalt_blobs, blob_key))
  end

  # Case-insensitive single-header lookup over the wire header map.
  defp header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  defp header_value(_, _), do: nil

  defp committed_etag(blob_key) do
    case Store.get(:smalt_blobs, blob_key) do
      {:ok, blob} -> blob["etag"]
      :error -> nil
    end
  end

  @doc """
  Get Block List (GET ?comp=blocklist&blocklisttype=all): returns
  `{:ok, committed, uncommitted}` where committed is the stored committed
  list and uncommitted is every staged block not in the committed list, or
  `:error` when the blob does not exist.
  """
  def get_block_list(account, container, blob_name) do
    ensure_block_table()
    blob_key = "#{account}/#{container}/#{blob_name}"

    committed =
      case Store.get(:smalt_blobs, blob_key) do
        {:ok, blob} -> blob["blocks"] || []
        :error -> []
      end

    committed_ids = MapSet.new(committed, & &1["block_id"])
    key_prefix = :erlang.iolist_to_binary(["#{account}/#{container}/#{blob_name}", 0])

    uncommitted =
      @block_table
      |> Store.prefix_keys(key_prefix)
      |> Enum.map(fn key ->
        {:ok, b} = Store.get(@block_table, key)
        b
      end)
      |> Enum.reject(&MapSet.member?(committed_ids, &1["block_id"]))
      |> Enum.sort_by(& &1["staged_at"])

    if committed == [] and uncommitted == [] do
      :error
    else
      {:ok, committed, uncommitted}
    end
  end

  @doc "Render committed/uncommitted block lists as the Azure BlockList XML document."
  def block_list_xml(committed, uncommitted) do
    committed_xml = render_block_section("CommittedBlocks", committed)
    uncommitted_xml = render_block_section("UncommittedBlocks", uncommitted)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <BlockList>
    #{committed_xml}#{uncommitted_xml}</BlockList>
    """
  end

  defp render_block_section(_tag, []), do: ""

  defp render_block_section(tag, blocks) do
    items =
      Enum.map_join(blocks, "\n", fn b ->
        "  <Block>\n    <Name>#{xml_escape(b["block_id"])}</Name>\n    <Size>#{b["size"]}</Size>\n  </Block>"
      end)

    "\n<" <> tag <> ">\n" <> items <> "\n</" <> tag <> ">\n"
  end

  @doc """
  Parse a Put Block List request body into ordered
  `{kind, block_id}` refs where kind is :latest | :committed | :uncommitted.
  Answers `{:error, 400, "InvalidXmlDocument", msg}` for a body with no
  block-list element (Azure wire shape for malformed XML).
  """
  def parse_block_list_xml(body) when is_binary(body) do
    refs =
      Regex.scan(
        ~r/<(Latest|Committed|Uncommitted)>([^<]*)<\/(?:Latest|Committed|Uncommitted)>/,
        body
      )
      |> Enum.map(fn [_all, tag, id] ->
        # SHIM-COURT R5: String.to_existing_atom/1 raises ArgumentError for
        # :latest/:committed/:uncommitted on a fresh node where those atoms
        # do not yet exist. Explicit binary match — total over the regex's
        # three possible tags, no atom-creation, no raise.
        kind =
          case tag do
            "Latest" -> :latest
            "Committed" -> :committed
            "Uncommitted" -> :uncommitted
          end

        {kind, xml_unescape(id)}
      end)

    if refs == [] do
      {:error, 400, "InvalidXmlDocument", "The block list body contains no block references."}
    else
      {:ok, refs}
    end
  end

  def parse_block_list_xml(_),
    do: {:error, 400, "InvalidXmlDocument", "The block list body must be XML."}

  # The python/JS SDKs send base64 block ids (entity-safe), but a hand-rolled
  # client may entity-escape & < > in the XML; unescape the common entities so
  # the id matches the staged key.
  defp xml_unescape(id) do
    id
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  @doc """
  DELETE blob. Returns:

    * `{:ok, 202, headers}` on success (`x-ms-request-id` header)
    * `{:error, 404, "BlobNotFound", msg}`
    * `{:error, 409, "ContainerLocked", msg}` when legal hold or locked
      immutability policy blocks the delete (message names the blocker)
    * `{:error, 412, "PreconditionFailed", msg}` on If-Match mismatch
  """
  def delete_blob(account, container, blob_name, headers \\ %{}, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         {:ok, existing} <- blob_or_404(blob_key),
         :ok <- check_worm(container_meta, now),
         :ok <- check_if_match(headers, existing["etag"]),
         :ok <- check_if_none_match(headers) do
      Store.delete(:smalt_blobs, blob_key)

      {:ok, 202, %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02"}, nil}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :not_found} -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", worm_message_reason(reason)}
      {:error, {:precondition}} -> {:error, 412, "PreconditionFailed", precondition_message()}
      {:error, {:precondition, _}} -> {:error, 412, "PreconditionFailed", precondition_message()}
    end
  end

  @valid_access_tiers ~w(Hot Cool Cold Archive)

  @doc """
  Set Blob Tier (`PUT ?comp=tier` + `x-ms-access-tier`) — stores the access
  tier on the blob record (GAP-AUD1-02). Valid tiers: Hot/Cool/Cold/Archive;
  anything else → 400 `InvalidHeaderValue`.

  Returns:

    * `{:ok, 200, headers, nil}`
    * `{:error, 400, "InvalidHeaderValue", msg}`
    * `{:error, 404, "ContainerNotFound" | "BlobNotFound", msg}`
  """
  def set_blob_tier(account, container, blob_name, tier, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         # SHIM-COURT / KD-COVERS: KD-52 — Set Blob Tier mutates the stored
         # blob, so it rides the "overwrite"-arm WORM check (legal hold,
         # locked policy, or unexpired retention -> 409 ContainerLocked).
         :ok <- check_worm_arm(container_meta, "overwrite", now),
         {:ok, existing} <- blob_or_404(blob_key) do
      if tier in @valid_access_tiers do
        updated =
          existing
          |> Map.put("access_tier", tier)
          |> Map.put("last_modified", DateTime.utc_now() |> DateTime.to_iso8601())

        Store.put(:smalt_blobs, blob_key, updated)
        {:ok, 200, %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02"}, nil}
      else
        {:error, 400, "InvalidHeaderValue",
         "Invalid x-ms-access-tier: #{inspect(tier)}. Valid: Hot, Cool, Cold, Archive."}
      end
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :not_found} -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", worm_message_reason(reason)}
    end
  end

  # ---------------------------------------------------------------------------
  # Blob snapshots (Put Blob ?comp=snapshot). A snapshot is an immutable,
  # point-in-time copy of the base blob's record (content, etag, headers,
  # metadata, tier) stored under a dedicated ETS table keyed {blob_key, ts}
  # so it never pollutes List Blobs enumeration. Later mutations of the base
  # blob must not be visible through the snapshot.
  # ---------------------------------------------------------------------------

  @snapshot_table :smalt_blob_snapshots

  @doc false
  def ensure_snapshot_table do
    if :ets.info(@snapshot_table) == :undefined do
      :ets.new(@snapshot_table, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Snapshot Blob (`PUT ?comp=snapshot`) — freezes the base blob's current
  record and returns the `x-ms-snapshot` timestamp in the response headers.

  Returns:

    * `{:ok, 201, %{"x-ms-snapshot" => ts, ...}, nil}`
    * `{:error, 404, "ContainerNotFound" | "BlobNotFound", msg}`
    * `{:error, 409, "ContainerLocked", msg}` when a legal hold blocks the
      snapshot create (WORM create arm)
  """
  def snapshot_blob(account, container, blob_name, _headers \\ %{}, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    ensure_snapshot_table()
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         # SHIM-COURT / KD-COVERS: KD-52 — a snapshot is a new blob seeded
         # from an existing one, so it resolves the existence-scoped arm per
         # the moduledoc convention: the source blob exists, making this a
         # "create" (hold-only) arm — legal hold blocks, time retention does
         # not (R5: immutability protects existing data, not namespace
         # growth).
         :ok <- check_worm_arm(container_meta, "create", now),
         {:ok, source} <- blob_or_404(blob_key) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      snapshot = Map.put(source, "snapshot", ts)
      :ets.insert(@snapshot_table, {{blob_key, ts}, snapshot})

      {:ok, 201,
       %{
         "x-ms-snapshot" => ts,
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02",
         "etag" => source["etag"]
       }, nil}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :not_found} -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", worm_message_reason(reason)}
    end
  end

  @doc """
  Get a specific snapshot of a blob by its `x-ms-snapshot` timestamp.
  Returns the frozen record (content, etag, headers) as of snapshot time.

    * `{:ok, blob}`
    * `{:error, 404, "BlobNotFound", msg}` — no such snapshot
  """
  def get_blob_snapshot(account, container, blob_name, ts) do
    ensure_snapshot_table()

    case :ets.lookup(@snapshot_table, {"#{account}/#{container}/#{blob_name}", ts}) do
      [{{_k, _ts}, blob}] -> {:ok, blob}
      [] -> {:error, 404, "BlobNotFound", "The specified blob snapshot does not exist."}
    end
  end

  @doc """
  List snapshots of a blob, newest first. Returns `{:ok, [blob, ...]}` where
  each element is the frozen record plus its `"snapshot"` timestamp
  (empty list when the blob has no snapshots).
  """
  def list_snapshots(account, container, blob_name) do
    ensure_snapshot_table()
    blob_key = "#{account}/#{container}/#{blob_name}"

    snapshots =
      @snapshot_table
      |> :ets.match_object({{blob_key, :_}, :_})
      |> Enum.map(fn {_k, blob} -> blob end)
      |> Enum.sort_by(fn blob -> blob["snapshot"] end, :desc)

    {:ok, snapshots}
  end

  # KD-107 RAISE (2026-10-20): lease-on-snapshot — `?comp=lease` addressed to a
  # snapshot (`?sharesnapshot=<ts>` on the blob path). Each snapshot row is its
  # own ETS record, so the lease id namespace is per-snapshot by construction.
  # Same action set / Azure shapes as lease_container/5; state rides the frozen
  # snapshot record (additive "lease" key). Wire arm lands in egress_router.ex
  # (other lane's file); this is the engine leg.
  @doc """
  Blob snapshot lease operations (`PUT ?comp=lease&sharesnapshot=<ts>` on the
  blob path, with `x-ms-lease-action`). State rides the frozen snapshot record
  in `:smalt_blob_snapshots` — per-snapshot lease id namespace.

  Returns `{:ok, status, headers, nil}` or `{:error, status, code, msg}`.
  """
  def lease_blob_snapshot(account, container, blob_name, ts, action, headers \\ %{}, opts \\ []) do
    ensure_snapshot_table()
    snap_key = {"#{account}/#{container}/#{blob_name}", ts}
    now = now_ms(opts)
    lease_id = header_value(headers, "x-ms-lease-id")

    with [{{_k, _ts}, snap}] <- :ets.lookup(@snapshot_table, snap_key) do
      case normalize_action(action) do
        :acquire ->
          with :ok <- validate_proposed_lease_id(headers),
               {:ok, seconds} <- lease_duration(headers) do
            if lease_active?(Map.get(snap, "lease"), now) do
              {:error, 409, "LeaseAlreadyPresent",
               "There is already a lease present on the snapshot."}
            else
              id = acquire_lease_id(headers)
              expires = if seconds == :infinity, do: :infinity, else: now + seconds * 1000

              new_lease = %{
                "id" => id,
                "state" => "leased",
                "expires_at" => expires,
                "duration" => seconds
              }

              put_snapshot_record(snap_key, Map.put(snap, "lease", new_lease))
              {:ok, 201, snapshot_lease_headers(snap, id), nil}
            end
          end

        :renew ->
          with :ok <- require_lease(snap, lease_id, now),
               {:ok, seconds} <- lease_duration(headers) do
            lease = extend_lease(Map.get(snap, "lease"), now, seconds)
            snap = Map.put(snap, "lease", lease)
            put_snapshot_record(snap_key, snap)
            {:ok, 200, snapshot_lease_headers(snap, Map.get(lease, "id")), nil}
          end

        :release ->
          with :ok <- require_lease(snap, lease_id, now, :leased_or_broken) do
            put_snapshot_record(snap_key, Map.delete(snap, "lease"))
            {:ok, 200, snapshot_lease_headers(snap, nil), nil}
          end

        :break ->
          with :ok <- require_lease(snap, lease_id, now, :leased_or_broken) do
            lease = Map.get(snap, "lease")

            remaining =
              case Map.get(lease, "expires_at") do
                :infinity -> 0
                ms when is_integer(ms) -> max(0, div(ms - now, 1000))
                _ -> 0
              end

            snap = Map.put(snap, "lease", Map.merge(lease, %{"state" => "broken", "expires_at" => nil}))
            put_snapshot_record(snap_key, snap)

            {:ok, 202,
             Map.put(snapshot_lease_headers(snap, Map.get(lease, "id")), "x-ms-lease-time", Integer.to_string(remaining)),
             nil}
          end

        other when other in [nil, :error] ->
          {:error, 400, "InvalidQueryParameterValue",
           "Invalid or missing x-ms-lease-action (expected acquire|renew|release|break)."}
      end
    else
      [] ->
        {:error, 404, "BlobNotFound", "The specified blob snapshot does not exist."}
    end
  end

  defp put_snapshot_record(snap_key, snap) do
    :ets.insert(@snapshot_table, {snap_key, snap})
  end

  # Snapshot lease success headers derive from the FROZEN blob record (quoted
  # etag + RFC 1123 Last-Modified from "last_modified"), not the container
  # record lease_success_headers/2 reads.
  defp snapshot_lease_headers(snap, lease_id) do
    {:ok, lm_dt, _} = DateTime.from_iso8601(snap["last_modified"])
    lm = Calendar.strftime(lm_dt, "%a, %d %b %Y %H:%M:%S GMT")

    base = %{
      "etag" => snap["etag"],
      "last-modified" => lm,
      "x-ms-request-id" => request_id(),
      "x-ms-version" => "2021-12-02"
    }

    if lease_id, do: Map.put(base, "x-ms-lease-id", lease_id), else: base
  end

  @doc """
  PUT ?comp=immutabilityPolicy — sets or locks the container immutability policy.
  Locking requires `If-Match: "*"`. After lock, changing the policy → 409
  `ContainerLocked`. Stored in `:smalt_blob_policy`.
  """
  def set_immutability_policy(account, container, policy, headers \\ %{}, opts \\ []) do
    container_key = container_key(account, container)
    now = now_ms(opts)
    ensure_policy_table()

    with {:ok, container_meta} <- fetch_container_meta(container_key),
         # R153: like set_legal_hold/set_container_metadata, the immutability
         # policy was an unlocked read-modify-write on the shared
         # :smalt_blob_policy row (public ETS, write_concurrency) — a legal-hold
         # commit landing between this read and its Store.put silently clobbered
         # the hold (and vice versa). The whole read-check-write now serializes
         # through the Store GenServer CAS: the lock/precondition checks run
         # INSIDE the update_fn against the freshly-read row, so a concurrent
         # writer forces a conflict-retry (re-read, re-check) or a typed
         # refusal — never a stale write-back over a committed field.
         :ok <-
           cas_policy_row(container_key, fn existing ->
             with :ok <- refuse_if_locked(existing, container_meta, now),
                  :ok <- require_star_if_match_for_lock(headers, policy),
                  {:ok, new_policy} <- build_immutability_policy(existing, policy, now) do
               {:ok, new_policy}
             else
               {:error, :locked} ->
                 {:error, 409, "ContainerLocked", locked_policy_message()}

               {:error, :if_match_required} ->
                 {:error, 412, "PreconditionFailed",
                  "Locking an immutability policy requires If-Match: \"*\"."}

               refused ->
                 refused
             end
           end) do
      # Response is projected from the COMMITTED row (the CAS closure wrote the
      # computed until/period_days into it) — never recomputed from the raw
      # request, which would drift from what is actually stored.
      committed = get_policy(account, container) || %{}
      imm = Map.get(committed, "immutability_policy", %{})
      locked = Map.get(imm, "locked", false)
      period_days = Map.get(imm, "period_days", 0)
      until = Map.get(imm, "until")

      base_headers = %{
        "x-ms-request-id" => request_id(),
        "x-ms-version" => "2021-12-02",
        "x-ms-has-immutability-policy" => "true"
      }

      # nil-safe projection: immutability-policy-until is only emitted when a
      # real expiry exists (period_days > 0 or a wire expiresOn was supplied).
      headers =
        if is_binary(until),
          do: Map.put(base_headers, "immutability-policy-until", until),
          else: base_headers

      {:ok, 200, headers, %{"locked" => locked, "until" => until, "period_days" => period_days}}
    else
      {:error, 400, code, msg} -> {:error, 400, code, msg}
      {:error, 404, code, msg} -> {:error, 404, code, msg}
      {:error, 409, code, msg} -> {:error, 409, code, msg}
      {:error, 412, code, msg} -> {:error, 412, code, msg}
      {:error, 500, code, msg} -> {:error, 500, code, msg}
    end
  end

  # R153: pure policy builder for the immutability write, run inside the CAS
  # closure against the freshly-read row. Preserves the pre-R153 semantics:
  # period_days falls back to the committed value, an explicit "until" => nil
  # falls through to the computed default, and the concurrent legal_hold field
  # is carried over from the row as read under serialization.
  defp build_immutability_policy(existing, policy, now) do
    locked = Map.get(policy, "locked", false)
    period_days = Map.get(policy, "period_days", Map.get(existing, "period_days", 0))

    case validate_period_days(period_days) do
      :ok ->
        # nil-coalescing: an explicit "until" => nil in the policy map must fall
        # through to the computed default, never propagate nil into a response
        # header (put_resp_header on nil is a FunctionClauseError 500).
        until = Map.get(policy, "until") || default_until(period_days, now)

        # R177d: seed from the row as read under CAS so sibling keys on the
        # shared :smalt_blob_policy row (e.g. "metadata" written by
        # set_container_metadata) survive the immutability PUT — merge, never
        # replace. SHIM-COURT: the pre-R177d fresh-map build clobbered them.
        {:ok,
         existing
         |> Map.put("immutability_policy", %{
           "locked" => locked,
           "until" => until,
           "period_days" => period_days
         })
         |> Map.put("legal_hold", Map.get(existing, "legal_hold", false))}

      {:error, 400, code, msg} ->
        {:error, 400, code, msg}
    end
  end

  @doc """
  Validate blob PUT content type (engine-level total: the wire always hands
  put_blob a binary body, but the engine answers 400, never a raise, for a
  non-binary content argument — a 500-class crash fenced per cycle-14).
  """
  @spec check_content(binary) :: :ok | {:error, 400, String.t(), String.t()}
  def check_content(content) when is_binary(content), do: :ok

  def check_content(_),
    do: {:error, 400, "InvalidInput", "Blob content must be a binary."}

  # Azure grammar: immutabilityPeriodSinceCreationInDays is an integer in
  # [0, 146000]; anything else is 400 InvalidXmlDocument (previously ANY value
  # was stored verbatim — negative days, binaries, 10^12 producing an
  # "until" in the year 2737909033).
  @max_retention_days 146_000

  defp validate_period_days(days)
       when is_integer(days) and days >= 0 and days <= @max_retention_days,
       do: :ok

  defp validate_period_days(_),
    do:
      {:error, 400, "InvalidXmlDocument",
       "immutabilityPeriodSinceCreationInDays must be an integer between 0 and 146000."}

  @doc """
  PUT/DELETE ?comp=legalhold — sets (`flag: true`) or clears (`flag: false`)
  the container legal hold. Stored in `:smalt_blob_policy`.
  """
  def set_legal_hold(account, container, flag, _headers \\ %{})

  def set_legal_hold(account, container, flag, _headers) when is_boolean(flag) do
    container_key = container_key(account, container)
    ensure_policy_table()

    with {:ok, _} <- Store.get(:smalt_blob_containers, container_key),
         # R133: policy-row writers were an unlocked read-modify-write on the
         # shared :smalt_blob_policy row (public ETS, write_concurrency) — a
         # metadata PUT landing between a hold-set's read and write silently
         # cleared the committed hold. Both writers now serialize through the
         # Store GenServer CAS: a stale write-back refuses and retries, and a
         # metadata set retrying re-reads the row that now carries the hold
         # and refuses with 409 (Azure ContainerLocked parity).
         :ok <-
           cas_policy_row(container_key, fn policy ->
             {:ok, policy |> Map.put("legal_hold", flag) |> put_in_worm_defaults()}
           end) do
      {:ok, 200,
       %{
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02",
         "x-ms-has-legal-hold" => to_string(flag)
       }, %{"has_legal_hold" => flag}}
    else
      # Store.get/2 returns a bare :error on a missing row — without this
      # clause the with raises WithClauseError (a 500), never a typed 404.
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :container_not_found} -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  # Azure parity (cycle-19): a non-boolean x-ms-legal-hold flag is a client
  # error — 400 InvalidHeaderValue, never a FunctionClauseError 500.
  def set_legal_hold(_account, _container, flag, _headers) do
    {:error, 400, "InvalidHeaderValue",
     "The value for x-ms-legal-hold must be true or false (got: #{inspect(flag)})."}
  end

  @doc "Returns the container's policy record or nil."
  def get_policy(account, container) do
    ensure_policy_table()

    case Store.get(@policy_table, "#{account}/#{container}") do
      {:ok, policy} -> policy
      :error -> nil
    end
  end

  def get_blob(account, container, blob_name) do
    Store.get(:smalt_blobs, "#{account}/#{container}/#{blob_name}")
  end

  @doc """
  PUT ?comp=metadata on a blob — Azure Put Blob Metadata REPLACES (never
  merges) the x-ms-meta-* subset of the blob's stored header map; other
  headers (content-type, content-encoding, ...) are preserved. Returns
  `{:ok, 200, headers}` (etag + x-ms-version) or `{:error, 404, ...}`.
  """
  def set_blob_metadata(account, container, blob_name, metadata, _headers \\ %{}) do
    blob_key = "#{account}/#{container}/#{blob_name}"
    # Engine totality (mirrors set_container_metadata): nil metadata = empty
    # replace set, never a FunctionClauseError 500.
    metadata = metadata || %{}
    now = now_ms([])

    with {:ok, blob} <- Store.get(:smalt_blobs, blob_key),
         # SHIM-COURT / KD-COVERS: KD-52 — a blob metadata PUT mutates the
         # blob, so it carries the same "overwrite"-class WORM check as
         # put_blob: legal hold or live locked/immutable policy -> 409
         # ContainerLocked (real Azure refuses metadata writes under hold).
         {:ok, container_meta} <- Store.get(:smalt_blob_containers, "#{account}/#{container}"),
         :ok <- check_metadata_names(meta_wire_headers(metadata)),
         :ok <-
           if(worm_blocked?(container_meta, "overwrite", now),
             do: {:worm, container_meta},
             else: :ok
           ) do
      stripped =
        Map.reject(blob["headers"] || %{}, fn {k, _v} ->
          String.starts_with?(k, "x-ms-meta-")
        end)

      # SHIM-COURT: Azure Put Blob Metadata updates ETag + Last-Modified. A
      # metadata mutation must yield a NEW etag (distinct from the body hash)
      # so pre-mutation If-Match fails with 412 (lost-update detection).
      # KD-COVERS: KD-52
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      new_etag = metadata_etag(blob["etag"], metadata, now)

      blob =
        blob
        |> Map.put("headers", Map.merge(stripped, meta_wire_headers(metadata)))
        |> Map.put("etag", new_etag)
        |> Map.put("last_modified", now)

      Store.put(:smalt_blobs, blob_key, blob)

      {:ok, 200,
       %{
         "etag" => new_etag,
         "x-ms-version" => "2021-12-02"
       }}
    else
      # SHIM-COURT: WORM-blocked metadata mutation -> 409 ContainerLocked
      # (same tuple shape as put_blob / commit_block_list).
      {:worm, container_meta} -> {:error, :worm_locked, worm_message(container_meta, now)}
      :error -> {:error, 404, "BlobNotFound", "Blob not found."}
      {:error, 400, _code, _msg} = invalid -> invalid
    end
  end

  # SHIM-COURT: metadata-set etag = MD5 of (stored etag, metadata, timestamp,
  # monotonic counter) — always distinct from the body-hash etag, even if the
  # same metadata is set twice.
  defp metadata_etag(prev_etag, metadata, now) do
    counter = System.unique_integer([:monotonic])

    digest =
      :crypto.hash(:md5, prev_etag <> inspect(metadata) <> now <> Integer.to_string(counter))
      |> Base.encode16(case: :lower)

    "\"#{digest}\""
  end

  defp meta_wire_headers(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} -> {"x-ms-meta-#{k}", v} end)
  end

  @doc """
  Content-free, wire-safe metadata projection of a stored blob: name, etag,
  content_length, last_modified, x-ms headers. Total over binary content —
  the raw `content` field is never included, so JSON encoding cannot raise.

  Security (MCP-lane finding, 2026-10-20): the projection previously emitted
  the FULL stored header map — including `authorization` (Bearer JWT) — into
  any surface that renders blob_metadata/1. It now projects only x-ms-*
  headers, so credential headers are structurally excluded.
  """
  def blob_metadata(blob) do
    blob
    |> Map.take(["name", "etag", "content_length", "last_modified", "headers"])
    |> Map.update("headers", %{}, fn
      h when is_map(h) ->
        Map.filter(h, fn {k, _} -> is_binary(k) and String.starts_with?(k, "x-ms-") end)

      _ ->
        %{}
    end)
  end

  @doc """
  Ranged GET engine: given the raw `Range` header list, returns

    * `{:ok, blob, nil}` — no usable range: serve full 200
    * `{:ok, blob, {first, last}}` — 0-based inclusive slice, 206 + Content-Range
    * `{:error, :range_not_satisfiable, total}` — 416 (start past EOF, suffix length 0)
    * `:error` — blob missing (404)

  Accepts `bytes=a-b`, `bytes=a-`, `bytes=-suffix`. A malformed range is
  ignored (RFC 9110: a syntactically invalid Range header MUST be ignored),
  serving the full body. Multi-range specs (`bytes=0-1,5-6`) are treated as
  malformed and ignored the same way (single-part 206 only; a first-spec-only
  slice is NOT served).
  """
  def get_blob_range(account, container, blob_name, range_header \\ [])

  def get_blob_range(account, container, blob_name, range_header) when is_list(range_header) do
    case Store.get(:smalt_blobs, "#{account}/#{container}/#{blob_name}") do
      {:ok, blob} ->
        total = byte_size(blob["content"])

        case parse_range(List.first(range_header), total) do
          {:ok, nil} ->
            {:ok, blob, nil}

          {:ok, {first, last}} ->
            {:ok, blob, {first, last}}

          :unsatisfiable ->
            {:error, :range_not_satisfiable, total}
        end

      :error ->
        :error
    end
  end

  def get_blob_range(_account, _container, _blob_name, _other), do: :error

  @doc """
  Conditional read engine (Azure parity, cycle-30 Get Blob): evaluates
  If-Match, then If-None-Match, then If-Modified-Since per RFC 7232
  precedence (AZB-06).

    * `{:ok, blob}` — preconditions pass (or absent): serve the read
    * `{:not_modified, etag}` — If-None-Match matched (incl. `*`), or
      If-Modified-Since present and the blob was NOT modified after that date
      (whole-second HTTP-date comparison): 304
    * `{:error, 412, "PreconditionFailed", msg}` — If-Match failed
    * `:error` — blob missing (404)
  """
  def get_blob_conditional(account, container, blob_name, headers) when is_map(headers) do
    case Store.get(:smalt_blobs, "#{account}/#{container}/#{blob_name}") do
      {:ok, blob} ->
        etag = blob["etag"]
        if_match = ConditionalHeaders.header(headers, "if-match")
        if_none_match = ConditionalHeaders.header(headers, "if-none-match")
        if_modified_since = ConditionalHeaders.header(headers, "if-modified-since")

        cond do
          if_match != nil and not conditional_etag_match?(if_match, etag) ->
            {:error, 412, "PreconditionFailed",
             "The condition specified using HTTP conditional header(s) is not met."}

          if_none_match != nil and conditional_etag_match?(if_none_match, etag) ->
            {:not_modified, etag}

          if_modified_since != nil and not modified_since?(blob["last_modified"], if_modified_since) ->
            {:not_modified, etag}

          true ->
            {:ok, blob}
        end

      :error ->
        :error
    end
  end

  def get_blob_conditional(_account, _container, _blob_name, _headers), do: :error

  # AZB-06 If-Modified-Since: HTTP-date comparison at whole-second
  # granularity (RFC 7232 §2.2 — the stored ISO-8601 last_modified is
  # truncated to seconds). Unparseable dates never match a 304 (serve the
  # read), never crash.
  defp modified_since?(last_modified, if_modified_since) do
    case {http_date_to_epoch(if_modified_since), iso8601_to_epoch(last_modified)} do
      {{ims, _raw}, {lm, _}} when ims != nil and lm != nil -> lm > ims
      _ -> true
    end
  end

  defp http_date_to_epoch(raw) do
    case :httpd_util.convert_request_date(to_charlist(raw)) do
      {{_y, _m, _d}, {_h, _mi, _s}} = cal ->
        # Same scale as iso8601_to_epoch: Unix seconds. The Gregorian-to-Unix
        # offset (62167219200 s) is a constant, not a wall-clock read.
        {:calendar.datetime_to_gregorian_seconds(cal) - 62_167_219_200, raw}

      _ ->
        {nil, raw}
    end
  end

  defp iso8601_to_epoch(raw) do
    case DateTime.from_iso8601(raw || "") do
      {:ok, dt, _off} ->
        {DateTime.to_unix(dt, :second), raw}

      {:error, _, _} ->
        {nil, raw}
    end
  end

  defp conditional_etag_match?("*", _etag), do: true

  defp conditional_etag_match?(value, etag) when is_binary(value) do
    String.split(value, ",") |> Enum.map(&String.trim/1) |> Enum.member?(etag)
  end

  defp conditional_etag_match?(_, _), do: false

  defp parse_range(nil, _total), do: {:ok, nil}

  defp parse_range(header, total) when is_binary(header) do
    case Regex.run(~r/^bytes=(\d*)-(\d*)$/, String.trim(header)) do
      [_, first, last] -> parse_range_spec(first, last, total)
      _ -> {:ok, nil}
    end
  end

  defp parse_range_spec("", "", _total), do: {:ok, nil}

  defp parse_range_spec(first, "", total) do
    first = String.to_integer(first)
    if first >= total, do: :unsatisfiable, else: {:ok, {first, total - 1}}
  end

  defp parse_range_spec("", last, total) do
    last = String.to_integer(last)
    if last <= 0, do: :unsatisfiable, else: {:ok, {max(total - last, 0), total - 1}}
  end

  defp parse_range_spec(first, last, total) do
    first = String.to_integer(first)
    last = String.to_integer(last)

    cond do
      first >= total -> :unsatisfiable
      last < first -> {:ok, nil}
      true -> {:ok, {first, min(last, total - 1)}}
    end
  end

  @max_page 50

  @doc """
  List blobs for `account`/`container` as Azure EnumerationResults XML.
  Options (binary-keyed, matching the query string): `"marker"`,
  `"maxresults"` (default 50, capped as in BlobService).

  Blobs are scanned by their ACTUAL stored key prefix
  `"\#{account}/\#{container}/"` via `Store.list_prefix/2` — same-named blobs
  in other containers of the account can never bleed in. Returns
  `{xml, next_marker}`; marker = last returned blob name, `NextMarker`
  present only when more results remain.
  """
  def list_blobs_xml(account, container, opts \\ %{}) do
    with :ok <- check_maxresults(Map.get(opts, "maxresults")) do
      do_list_blobs_xml(account, container, opts)
    end
  end

  defp do_list_blobs_xml(account, container, opts) do
    key_prefix = "#{account}/#{container}/"
    marker = Map.get(opts, "marker") || ""
    prefix = Map.get(opts, "prefix") || ""
    delimiter = Map.get(opts, "delimiter") || ""
    include = Map.get(opts, "include")
    max_results = normalize_max(Map.get(opts, "maxresults"))

    if delimiter == "" and prefix == "" and marker == "" do
      # Fast path (perf contract fence): sorted key scan, values fetched only
      # for the page — the delimiter/prefix/marker composition below
      # materializes element tuples for the full key set.
      keys = :smalt_blobs |> Store.prefix_keys(key_prefix) |> Enum.sort()
      page_keys = Enum.take(keys, max_results)

      next_marker =
        if length(keys) > max_results,
          do: String.replace_prefix(List.last(page_keys), key_prefix, ""),
          else: nil

      xml =
        render_blobs(
          page_keys,
          next_marker,
          account,
          container,
          marker,
          max_results,
          "",
          prefix,
          key_prefix,
          include
        )

      {xml, next_marker}
    else
      # Delimiter/prefix/marker composition (Azure parity, cycle-27):
      # names containing the delimiter (after the requested prefix) roll
      # into a single synthetic <BlobPrefix> per directory; Blob/BlobPrefix
      # interleave lexicographically; prefixes count toward maxresults;
      # NextMarker continues from the last element name.
      elements =
        :smalt_blobs
        |> Store.prefix_keys(key_prefix)
        |> Enum.map(fn key ->
          name = binary_part(key, byte_size(key_prefix), byte_size(key) - byte_size(key_prefix))

          rel =
            if prefix == "" or not String.starts_with?(name, prefix),
              do: nil,
              else: binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix))

          cond do
            prefix != "" and rel == nil ->
              :skip

            delimiter != "" and String.contains?(name, delimiter) and
                (prefix == "" or String.contains?(rel, delimiter)) ->
              {:bp, prefix <> hd(String.split(rel || name, delimiter)) <> delimiter, nil}

            true ->
              {:blob, name, key}
          end
        end)
        |> Enum.reject(&(&1 == :skip))
        |> Enum.uniq()
        |> Enum.filter(fn {_t, n, _k} -> marker == "" or n > marker end)
        |> Enum.sort_by(fn {_t, n, _k} -> n end)

      page = Enum.take(elements, max_results)

      next_marker = if length(elements) > max_results, do: elem(List.last(page), 1), else: nil

      delimiter_xml =
        if delimiter == "", do: "", else: "\n  <Delimiter>#{xml_escape(delimiter)}</Delimiter>"

      blob_items =
        Enum.map_join(page, "\n", fn
          {:blob, name, key} ->
            render_blob(name, key, key_prefix, include)

          {:bp, bp_name, _} ->
            "\n  <BlobPrefix>\n    <Name>#{xml_escape(bp_name)}</Name>\n  </BlobPrefix>\n "
        end)

      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/#{xml_escape(account)}" ContainerName="#{xml_escape(container)}">
        <Prefix>#{xml_escape(if(prefix == "", do: key_prefix, else: prefix))}</Prefix>#{delimiter_xml}
        <Marker>#{xml_escape(marker)}</Marker>
        <MaxResults>#{max_results}</MaxResults>
        <Blobs>
      #{blob_items}
        </Blobs>
      #{next_marker_xml(next_marker)}
      </EnumerationResults>
      """

      {xml, next_marker}
    end
  end

  # Prefix echo mirrors the composed path's expression exactly (defect 4,
  # v26.10.14 lane 06): the fast path previously interpolated the full stored
  # key prefix directly instead of routing through the same
  # `if(prefix == "", do: key_prefix, else: prefix)` echo.
  defp render_blobs(
         page_keys,
         next_marker,
         account,
         container,
         marker,
         max_results,
         delimiter_xml,
         prefix,
         key_prefix,
         include
       ) do
    items =
      Enum.map_join(page_keys, "\n", fn key ->
        render_blob(String.replace_prefix(key, key_prefix, ""), key, key_prefix, include)
      end)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/#{xml_escape(account)}" ContainerName="#{xml_escape(container)}">
      <Prefix>#{xml_escape(if(prefix == "", do: key_prefix, else: prefix))}</Prefix>#{delimiter_xml}
      <Marker>#{xml_escape(marker)}</Marker>
      <MaxResults>#{max_results}</MaxResults>
      <Blobs>
    #{items}
      </Blobs>
    #{next_marker_xml(next_marker)}
    </EnumerationResults>
    """
  end

  defp render_blob(name, key, _key_prefix, include) do
    case Store.get(:smalt_blobs, key) do
      {:ok, b} ->
        """
        <Blob>
          <Name>#{xml_escape(b["name"] || name)}</Name>#{blob_metadata_xml(b, include)}<Properties>
            <Content-Length>#{b["content_length"]}</Content-Length>
            <Etag>#{xml_escape(b["etag"])}</Etag>
            <Last-Modified>#{xml_escape(b["last_modified"])}</Last-Modified>
          </Properties>
        </Blob>
        """ <> snapshots_xml(key, b, include)

      _ ->
        ""
    end
  end

  # KD-107 RAISE (2026-10-20): include=snapshots decorates — each snapshot of
  # the base blob renders as its own <Blob> entry carrying a <Snapshot>
  # timestamp element (Azure List Blobs shape), instead of the previously
  # silently-absent rows. Snapshots sort ascending by timestamp, matching the
  # base-blob entry order.
  defp snapshots_xml(blob_key, _b, include) do
    if include_snapshots?(include) do
      blob_key
      |> list_snapshots_by_key()
      |> Enum.map(fn snap ->
        """
        <Blob>
          <Name>#{xml_escape(snap["name"])}</Name>
          <Snapshot>#{xml_escape(snap["snapshot"])}</Snapshot>
          <Properties>
            <Content-Length>#{snap["content_length"]}</Content-Length>
            <Etag>#{xml_escape(snap["etag"])}</Etag>
            <Last-Modified>#{xml_escape(snap["last_modified"])}</Last-Modified>
          </Properties>
        </Blob>
        """
      end)
      |> Enum.join("")
    else
      ""
    end
  end

  defp list_snapshots_by_key(blob_key) do
    ensure_snapshot_table()

    @snapshot_table
    |> :ets.match_object({{blob_key, :_}, :_})
    |> Enum.map(fn {_k, blob} -> blob end)
    |> Enum.sort_by(fn blob -> blob["snapshot"] end, :asc)
  end

  defp include_snapshots?(include) when is_binary(include) do
    include
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.member?("snapshots")
  end

  defp include_snapshots?(_), do: false

  defp include_metadata?(include) when is_binary(include) do
    include
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.member?("metadata")
  end

  defp include_metadata?(_), do: false

  # Azure parity (cycle-34, List Blobs include=metadata): user metadata rides
  # x-ms-meta-* on the stored headers; when the request includes metadata the
  # listing emits a <Metadata> element per blob. Values go through the same
  # xml_escape (hostile & < > " entity-escaped; control chars are refused at
  # PUT by the InvalidMetadata fence). Only the exact "metadata" include
  # token enables it; the exact "snapshots" token additionally decorates
  # snapshot rows (KD-107 RAISE, snapshots_xml/3); versions/tags remain
  # admitted-but-undecorated.
  defp blob_metadata_xml(_b, false), do: ""

  # include is the RAW comma-separated token string (passing a boolean here was
  # fine when render_blob only ever passed include_metadata?/1's result — the
  # KD-107 RAISE threading now passes the raw token list through, so accept
  # both; a raw string without the exact "metadata" token is also "").
  defp blob_metadata_xml(b, include) when is_binary(include),
    do: blob_metadata_xml(b, include_metadata?(include))

  defp blob_metadata_xml(b, true) do
    meta =
      b["headers"]
      |> Kernel.||(%{})
      |> Enum.filter(fn {k, _} -> is_binary(k) and String.starts_with?(k, "x-ms-meta-") end)
      |> Enum.map_join("\n", fn {"x-ms-meta-" <> name, value} ->
        "<#{xml_escape(name)}>#{xml_escape(value)}</#{xml_escape(name)}>"
      end)

    if meta == "", do: "", else: "\n  <Metadata>\n#{meta}\n  </Metadata>"
  end

  @doc """
  XML-escape a value for safe interpolation into element text or attribute
  values (real Blob service escapes all listing output; unescaped blob or
  container names containing `<`, `>`, `&`, `"` produce malformed
  EnumerationResults XML). Non-binary falls back to the empty string so a
  nil name can never raise.
  """
  @spec xml_escape(term) :: String.t()
  def xml_escape(nil), do: ""

  def xml_escape(value) when is_binary(value) do
    # XML 1.0 forbids most C0 control bytes in content (only \t \n \r are
    # legal). Hostile stored names / marker or prefix query params must never
    # produce ill-formed enumeration XML — illegal control bytes are dropped;
    # & < > " are entity-escaped as before.
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    # Astral-plane codepoints (> U+FFFF) are legal XML 1.0 content but a real
    # parser family (xmerl 2.x, lens2 cycle-35 falsifier: emoji blob name
    # listing) rejects the raw UTF-8 form with wfc_Legal_Character. A numeric
    # character reference is semantically IDENTICAL XML (same parsed content)
    # and parses under every XML 1.0 parser — Azure parity preserved (same
    # name after parse), parser-compat hardened.
    |> String.replace(~r/[\x{10000}-\x{10FFFF}]/u, fn <<cp::utf8>> ->
      "&#x" <> String.downcase(Integer.to_string(cp, 16)) <> ";"
    end)
  end

  def xml_escape(value), do: value |> to_string() |> xml_escape()

  defp normalize_max(nil), do: @max_page

  defp normalize_max(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> min(n, @max_page)
      _ -> @max_page
    end
  end

  defp normalize_max(n) when is_integer(n) and n > 0, do: min(n, @max_page)
  defp normalize_max(_), do: @max_page

  defp next_marker_xml(nil), do: "<NextMarker />"

  defp next_marker_xml(marker), do: "<NextMarker>#{xml_escape(marker)}</NextMarker>"

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp store_blob(account, container, blob_name, content, headers) do
    etag = "\"#{:crypto.hash(:md5, content) |> Base.encode16(case: :lower)}\""

    blob = %{
      "name" => blob_name,
      "content" => content,
      "content_length" => byte_size(content),
      "etag" => etag,
      "last_modified" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "headers" => headers
    }

    Store.put(:smalt_blobs, "#{account}/#{container}/#{blob_name}", blob)

    # AZB-06 durability: with `persistence: :dets_mirrored, sync_interval_ms: 0`
    # the acknowledged write is fsynced to the mirror before this function
    # returns (so before the HTTP 201/200 ack). No profile / no mirror => no-op.
    Smalt.Store.DetsMirror.sync_write(:smalt_blobs)

    {:ok, blob}
  end

  # AZB-06 If-Match race: the replace runs as ONE Store compare_and_swap so
  # exactly one concurrent racer wins. On CAS conflict we re-read and re-check
  # the caller's If-Match against the CURRENT etag — the first writer already
  # moved it, so the losers take the 412 path; if the current etag still
  # matches (e.g. a metadata mutation raced in between) we retry the CAS.
  defp cas_replace(account, container, blob_name, content, headers, expected) do
    etag = "\"#{:crypto.hash(:md5, content) |> Base.encode16(case: :lower)}\""
    blob_key = "#{account}/#{container}/#{blob_name}"

    blob = %{
      "name" => blob_name,
      "content" => content,
      "content_length" => byte_size(content),
      "etag" => etag,
      "last_modified" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "headers" => headers
    }

    case Store.compare_and_swap(:smalt_blobs, blob_key, expected, blob) do
      :ok ->
        Smalt.Store.DetsMirror.sync_write(:smalt_blobs)
        {:ok, blob}

      {:error, :conflict} ->
        case Store.get(:smalt_blobs, blob_key) do
          {:ok, current} ->
            if mismatched_if_match?(headers, current["etag"]) do
              {:error, :precondition_failed, precondition_message()}
            else
              cas_replace(account, container, blob_name, content, headers, current)
            end

          # Deleted concurrently while we held a stale expect — an If-Match
          # precondition on a resource that no longer exists fails (cycle-21).
          :error ->
            {:error, :precondition_failed, precondition_message()}
        end
    end
  end

  defp mismatched_if_match?(headers, current_etag) do
    case ConditionalHeaders.header(headers || %{}, "if-match") do
      nil -> false
      _value -> ConditionalHeaders.evaluate(headers, current_etag) == {:halt, 412}
    end
  end

  defp if_none_match_star?(headers) do
    case ConditionalHeaders.header(headers || %{}, "if-none-match") do
      nil -> false
      "*" -> true
      _ -> false
    end
  end

  defp check_if_match(headers, current_etag) do
    case ConditionalHeaders.header(headers || %{}, "if-match") do
      nil ->
        :ok

      _ ->
        if ConditionalHeaders.evaluate(headers, current_etag) == {:halt, 412},
          do: {:error, {:precondition}},
          else: :ok
    end
  end

  # Azure parity (cycle-22): If-None-Match: * refuses deletion of an existing
  # blob with 412 — previously silently ignored (202 on a refuse-if-exists
  # precondition).
  defp check_if_none_match(headers) do
    case if_none_match_star?(headers) do
      true -> {:error, {:precondition}}
      false -> :ok
    end
  end

  defp check_worm(container_meta, now) do
    if worm_blocked?(container_meta, "delete", now) do
      {:error, {:worm, blocker(fetch_policy(container_meta))}}
    else
      :ok
    end
  end

  # SHIM-COURT: verb-parameterized check_worm — resolves the caller's WORM
  # arm ("create" / "overwrite" / "delete") per the moduledoc convention.
  defp check_worm_arm(container_meta, arm, now) do
    if worm_blocked?(container_meta, arm, now) do
      {:error, {:worm, blocker(fetch_policy(container_meta))}}
    else
      :ok
    end
  end

  # WORM block when a legal hold is set (never expires), or the immutability
  # policy is locked / container is immutable while retention is still live.
  # Once `now > created_at + retention_days` the container unlocks — except
  # for an active legal hold, which only an explicit release lifts.
  # Create arm ("create"): only a legal hold blocks NEW-blob creation
  # (R5); time-retention/immutable containers still accept new blobs,
  # matching the pre-existing retention-expiry test expectations.
  defp worm_blocked?(container_meta, "create", _now) do
    legal_hold?(fetch_policy(container_meta))
  end

  defp worm_blocked?(container_meta, _op, now) do
    policy = fetch_policy(container_meta)

    cond do
      legal_hold?(policy) -> true
      expired?(container_meta, now) -> false
      locked_policy?(policy) -> true
      Map.get(container_meta, "immutable") == true and not policy_present?(policy) -> true
      true -> false
    end
  end

  # Retention expiry: now strictly past created_at + retention_days.
  # Legacy containers without created_at are conservatively never expired.
  defp expired?(_container_meta, _now, created_at) when is_nil(created_at), do: false

  defp expired?(container_meta, now, created_at) do
    now > created_at + retention_ms(container_meta)
  end

  defp expired?(container_meta, now) do
    expired?(container_meta, now, Map.get(container_meta, "created_at"))
  end

  defp retention_end_ms(container_meta) do
    case Map.get(container_meta, "created_at") do
      nil -> nil
      created_at -> created_at + retention_ms(container_meta)
    end
  end

  defp retention_ms(container_meta) do
    Map.get(container_meta, "retention_days", 1095) * 86_400_000
  end

  defp now_ms(opts) when is_list(opts) do
    Keyword.get(opts, :now_ms) || System.os_time(:millisecond)
  end

  defp now_ms(opts) when is_map(opts), do: now_ms(Enum.to_list(opts))

  defp fetch_policy(container_meta) do
    ensure_policy_table()

    case Store.get(@policy_table, "#{container_meta["account"]}/#{container_meta["container"]}") do
      {:ok, p} -> p
      :error -> nil
    end
  end

  defp policy_present?(nil), do: false
  defp policy_present?(policy), do: Map.has_key?(policy, "immutability_policy")

  defp legal_hold?(policy), do: !!policy && !!Map.get(policy, "legal_hold")

  defp locked_policy?(nil), do: false

  defp locked_policy?(policy) do
    case Map.get(policy, "immutability_policy") do
      %{"locked" => true} -> true
      _ -> false
    end
  end

  defp blocker(policy) do
    cond do
      legal_hold?(policy) -> :legal_hold
      locked_policy?(policy) -> :locked_policy
      true -> :legacy_immutable
    end
  end

  defp worm_message(container_meta, _now) do
    container_meta
    |> fetch_policy()
    |> blocker()
    |> worm_message_reason()
  end

  defp worm_message_reason(:legal_hold),
    do: "Blob modification refused: container has an active legal hold (ContainerLocked)."

  defp worm_message_reason(:locked_policy),
    do: "Blob modification refused: container immutability policy is locked (ContainerLocked)."

  defp worm_message_reason(:legacy_immutable),
    do: "Blob modification refused: container policy enforces immutable WORM retention."

  defp locked_policy_message,
    do: "Immutability policy is locked and can no longer be changed (ContainerLocked)."

  defp precondition_message,
    do: "The condition specified using HTTP conditional header(s) is not met."

  defp blob_or_404(blob_key) do
    case Store.get(:smalt_blobs, blob_key) do
      {:ok, blob} -> {:ok, blob}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  R133: serialized policy-row update. `update_fn` receives the current policy
  map (or `%{}` when absent) and returns `{:ok, new_policy}` or an
  `{:error, status, code, msg}` tuple to abort without writing. The
  read-check-write runs as ONE Store GenServer `compare_and_swap`/`insert_new`
  on the whole row, so a concurrent writer between the read and the write
  yields `{:error, :conflict}` and the update re-reads + retries — a stale
  write-back can never clobber a concurrently committed field (e.g. a
  metadata PUT clearing a just-committed legal hold). After a bounded number
  of conflicts the update fails closed with 500. Convergence: each conflict
  consumes one competitor commit, so conflicts are bounded by the concurrent
  commits during the spin (<= racer count N, N << 200) — a racer that wins
  its CAS retires and stops generating conflicts. 500-on-exhaustion is
  fail-closed: the caller gets a loud error, the hold can never be silently
  lost.
  """
  def cas_policy_row(container_key, update_fn) do
    ensure_policy_table()
    cas_policy_row_loop(container_key, update_fn, 200)
  end

  defp cas_policy_row_loop(_container_key, _update_fn, 0) do
    {:error, 500, "OperationFailed", "policy row contention: update did not converge"}
  end

  defp cas_policy_row_loop(container_key, update_fn, attempts) do
    case Store.get(@policy_table, container_key) do
      {:ok, current} ->
        case update_fn.(current) do
          {:ok, new_policy} ->
            case Store.compare_and_swap(@policy_table, container_key, current, new_policy) do
              :ok -> :ok
              {:error, :conflict} -> cas_policy_row_loop(container_key, update_fn, attempts - 1)
            end

          # typed abort (e.g. 409 ContainerLocked under a concurrently
          # committed hold) — no write, no retry
          {:error, _, _, _} = refused ->
            refused
        end

      :error ->
        case update_fn.(%{}) do
          {:ok, new_policy} ->
            case Store.insert_new(@policy_table, container_key, new_policy) do
              :ok -> :ok
              # row appeared between get and insert_new — re-read and retry
              {:error, :exists} -> cas_policy_row_loop(container_key, update_fn, attempts - 1)
            end

          {:error, _, _, _} = refused ->
            refused
        end
    end
  end

  # A locked policy refuses change — unless retention has already expired,
  # in which case the container is unlocked and the policy may be changed.
  # Missing container on the policy path must be a typed 404, never a
  # WithClauseError 500 (C4-fix residual).
  defp fetch_container_meta(container_key) do
    case Store.get(:smalt_blob_containers, container_key) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  defp refuse_if_locked(existing, container_meta, now) do
    if locked_policy?(existing) and not expired?(container_meta, now) do
      {:error, :locked}
    else
      :ok
    end
  end

  defp require_star_if_match_for_lock(headers, policy) do
    if Map.get(policy, "locked", false) do
      case ConditionalHeaders.header(headers || %{}, "if-match") do
        "*" -> :ok
        _ -> {:error, :if_match_required}
      end
    else
      :ok
    end
  end

  defp put_in_worm_defaults(policy) do
    Map.put_new(policy, "immutability_policy", %{
      "locked" => false,
      "until" => nil,
      "period_days" => 0
    })
  end

  defp default_until(days, now_ms) when is_integer(days) and days > 0 do
    DateTime.from_unix!(now_ms, :millisecond)
    |> DateTime.add(days * 86_400)
    |> DateTime.to_iso8601()
  end

  defp default_until(_, _), do: nil

  # ---------------------------------------------------------------------------
  # KD-COVERS: KD-108 — container lease + ACL surface.
  # Container lease (KD-108) — `?comp=lease` surface. Lease state lives in the
  # container row's existing map (additive "lease" key, no new Store table).
  # Azure shapes: acquire -> 201 + ETag/Last-Modified/x-ms-lease-id; renew ->
  # 200; release -> 200; break -> 202 + x-ms-lease-time. An ACTIVE lease
  # (state "leased", unexpired) blocks Delete Container -> 409 ContainerLeased
  # unless the request carries the matching x-ms-lease-id; a BROKEN lease does
  # not block (Azure parity: break leaves the lease breakable-releaseable).
  # ---------------------------------------------------------------------------
  @lease_actions ~w(acquire renew release break)

  @doc """
  Container lease operations (`PUT ?comp=lease&restype=container` with
  `x-ms-lease-action`). State rides the container record map — no new table.
  Returns `{:ok, status, headers, nil}` or `{:error, status, code, msg}`.
  """
  def lease_container(account, container, action, headers \\ %{}, opts \\ []) do
    container_key = container_key(account, container)
    now = now_ms(opts)
    lease_id = header_value(headers, "x-ms-lease-id")

    with {:ok, record} <- Store.get(:smalt_blob_containers, container_key) do
      case normalize_action(action) do
        :acquire ->
          # KD-108 RAISE: honor x-ms-proposed-lease-id on acquire (Azure parity —
          # the kd108 witness showed a client-proposed id being ignored, minting
          # a fresh UUID and breaking the caller's renew/break/release legs).
          # Malformed GUID -> 400 InvalidHeaderValue.
          with :ok <- validate_proposed_lease_id(headers),
               {:ok, seconds} <- lease_duration(headers) do
            lease = Map.get(record, "lease")

            if lease_active?(lease, now) do
              {:error, 409, "LeaseAlreadyPresent",
               "There is already a lease present on the container."}
            else
              id = acquire_lease_id(headers)
              expires = if seconds == :infinity, do: :infinity, else: now + seconds * 1000

              new_lease = %{
                "id" => id,
                "state" => "leased",
                "expires_at" => expires,
                "duration" => seconds
              }

              put_lease(container_key, record, new_lease)
              {:ok, 201, lease_success_headers(record, id), nil}
            end
          end

        :renew ->
          with :ok <- require_lease(record, lease_id, now),
               {:ok, seconds} <- lease_duration(headers) do
            lease = extend_lease(Map.get(record, "lease"), now, seconds)
            put_lease(container_key, record, lease)
            {:ok, 200, lease_success_headers(record, Map.get(lease, "id")), nil}
          end

        :release ->
          with :ok <- require_lease(record, lease_id, now, :leased_or_broken) do
            put_lease(container_key, record, Map.delete(record, "lease"))
            {:ok, 200, lease_success_headers(record, nil), nil}
          end

        :break ->
          with :ok <- require_lease(record, lease_id, now, :leased_or_broken) do
            lease = Map.get(record, "lease")

            remaining =
              case Map.get(lease, "expires_at") do
                :infinity -> 0
                ms when is_integer(ms) -> max(0, div(ms - now, 1000))
                _ -> 0
              end

            broken = Map.merge(lease, %{"state" => "broken", "expires_at" => nil})

            put_lease(container_key, record, broken)
            {:ok, 202, Map.put(lease_success_headers(record, Map.get(lease, "id")), "x-ms-lease-time", Integer.to_string(remaining)), nil}
          end

        other when other in [nil, :error] ->
          {:error, 400, "InvalidQueryParameterValue",
           "Invalid or missing x-ms-lease-action (expected acquire|renew|release|break)."}
      end
    else
      :error -> {:error, 404, "ContainerNotFound", "The specified container does not exist."}
    end
  end

  defp normalize_action(a) when is_binary(a) do
    case String.downcase(a) do
      a when a in @lease_actions -> String.to_existing_atom(a)
      _ -> :error
    end
  end

  defp normalize_action(_), do: :error

  # NOTE: lease-id presence rules — release/break/renew REQUIRE a lease id
  # header; acquire does not. Mismatch is 409 LeaseIdMismatchWithLeaseOperation.
  # Renew requires an ACTIVE lease; release/break accept a lease in either
  # the leased OR broken state (Azure parity: break leaves the lease
  # breakable-releaseable — refusing release after break deadlocks the lease).
  defp require_lease(record, lease_id, now, mode \\ :active) do
    lease = Map.get(record, "lease")
    present? = lease_active?(lease, now) or mode == :leased_or_broken and lease_present?(lease)

    cond do
      not present? ->
        {:error, 409, "LeaseNotPresentWithLeaseOperation",
         "There is no active lease on the container."}

      is_nil(lease_id) ->
        {:error, 409, "LeaseIdMismatchWithLeaseOperation",
         "The lease id is missing (send the x-ms-lease-id header)."}

      lease_id != Map.get(lease, "id") ->
        {:error, 409, "LeaseIdMismatchWithLeaseOperation",
         "The lease id specified did not match the lease id for the container."}

      true ->
        :ok
    end
  end

  defp lease_present?(lease) when is_map(lease), do: Map.get(lease, "state") in ["leased", "broken"]
  defp lease_present?(_), do: false

  defp lease_active?(nil, _now), do: false

  defp lease_active?(lease, now) when is_map(lease) do
    Map.get(lease, "state") == "leased" and
      (Map.get(lease, "expires_at") == :infinity or
         (is_integer(Map.get(lease, "expires_at")) and Map.get(lease, "expires_at") > now))
  end

  # x-ms-lease-duration: "-1" (infinite) or a positive integer seconds; absent
  # defaults to infinite (Azure parity for acquire). Anything else is a typed
  # 400 InvalidHeaderValue.
  defp lease_duration(headers) do
    case header_value(headers, "x-ms-lease-duration") do
      nil ->
        {:ok, :infinity}

      "-1" ->
        {:ok, :infinity}

      raw when is_binary(raw) ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, 400, "InvalidHeaderValue", "x-ms-lease-duration must be -1 or a positive integer number of seconds."}
        end

      _ ->
        {:error, 400, "InvalidHeaderValue", "x-ms-lease-duration must be -1 or a positive integer number of seconds."}
    end
  end

  # x-ms-proposed-lease-id (KD-108 RAISE): when present on acquire it is the
  # lease id Azure returns verbatim; a non-GUID value is 400 InvalidHeaderValue.
  # Azure Guid.TryParse accepts both dashed ("D") and 32-hex no-dash ("N")
  # forms — the kd108 probe shape is N-format, so both are admitted.
  @lease_id_guid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$|^[0-9a-fA-F]{32}$/

  defp validate_proposed_lease_id(headers) do
    case header_value(headers, "x-ms-proposed-lease-id") do
      nil ->
        :ok

      id ->
        if Regex.match?(@lease_id_guid, id),
          do: :ok,
          else:
            {:error, 400, "InvalidHeaderValue",
             "x-ms-proposed-lease-id must be a valid GUID."}
    end
  end

  defp acquire_lease_id(headers) do
    case header_value(headers, "x-ms-proposed-lease-id") do
      nil -> request_id()
      id -> id
    end
  end

  defp extend_lease(lease, _now, :infinity), do: Map.put(lease, "expires_at", :infinity)

  defp extend_lease(lease, now, n) when is_integer(n),
    do: Map.put(lease, "expires_at", now + n * 1000)

  defp container_key(account, container), do: account <> "/" <> container

  defp put_lease(container_key, record, lease) do
    record = Map.put(record, "lease", lease)
    Store.put(:smalt_blob_containers, container_key, record)
  end

  # Standard success header set for lease ops (Azure shape): quoted ETag +
  # RFC 1123 Last-Modified from the container record, x-ms-lease-id when one
  # applies, request-id + version stamped by blob_route entry.
  defp lease_success_headers(record, lease_id) do
    {:ok, created_dt, _} = DateTime.from_iso8601(record["created"])
    lm = Calendar.strftime(created_dt, "%a, %d %b %Y %H:%M:%S GMT")

    base = %{
      "etag" => container_etag_value(record),
      "last-modified" => lm,
      "x-ms-request-id" => request_id(),
      "x-ms-version" => "2021-12-02"
    }

    if lease_id, do: Map.put(base, "x-ms-lease-id", lease_id), else: base
  end

  # BlobService.container_etag/1 is the canonical quoted container ETag
  # (md5 of account/container/created_at); reuse, never re-derive.
  defp container_etag_value(record), do: BlobService.container_etag(record)

  # Azure Delete Container conflict: an ACTIVE lease (leased + unexpired)
  # refuses 409 ContainerLeased unless the request carries the matching
  # x-ms-lease-id. A broken or absent lease never blocks.
  defp check_lease_on_delete(container_meta, headers, now) do
    lease = Map.get(container_meta, "lease")

    if lease_active?(lease, now) do
      supplied = header_value(headers, "x-ms-lease-id")

      if supplied == Map.get(lease, "id") do
        :ok
      else
        {:error, 409, "ContainerLeased",
         "There is currently a lease on the container and no lease ID was specified in the request."}
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Container ACL / signed identifiers (KD-108) — GET/PUT ?comp=acl&restype=
  # container. Stored as an additive "acl" key in the container row's map
  # (list of identifier maps). Azure shapes: PUT -> 204 No Content; GET ->
  # 200 SignedIdentifiers XML. Bounded at 5 signed identifiers; permission
  # letters restricted to rpwdl. When SAS verification (lib/smalt/auth/sas.ex)
  # evaluates signed identifiers, it reads this row via get_acl/2.
  # ---------------------------------------------------------------------------
  @max_signed_identifiers 5
  # KD-108 RAISE (2026-10-20): full Azure container permission set. Real Azure
  # container ACLs accept r/a/c/w/d/l (the previous r/p/w/d/l set refused
  # `racwdl` with 400 InvalidXmlDocument — kd108 witness divergence #2).
  @acl_permissions ~w(r a c w d l)

  @doc "Signed identifiers for a container (stored additive in the container row)."
  def get_acl(account, container) do
    case Store.get(:smalt_blob_containers, container_key(account, container)) do
      {:ok, record} -> {:ok, Map.get(record, "acl", [])}
      :error -> {:error, :container_not_found}
    end
  end

  @doc """
  Put Container ACL: store <=5 signed identifiers. Body is the Azure
  SignedIdentifiers XML (parsed here); an empty body clears the ACL.
  Returns `{:ok, 204, headers, nil}` or `{:error, status, code, msg}`.
  """
  def set_container_acl(account, container, body, _headers \\ %{}, _opts \\ []) do
    container_key = container_key(account, container)

    with {:ok, record} <- Store.get(:smalt_blob_containers, container_key),
         {:ok, identifiers} <- parse_signed_identifiers(body) do
      record = Map.put(record, "acl", identifiers)
      Store.put(:smalt_blob_containers, container_key, record)

      {:ok, 204,
       %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02",
         "etag" => container_etag_value(record),
         "last-modified" => Calendar.strftime(DateTime.from_iso8601(record["created"]) |> elem(1), "%a, %d %b %Y %H:%M:%S GMT")},
       nil}
    else
      :error -> {:error, 404, "ContainerNotFound", "The specified container does not exist."}
      {:error, _, _, _} = e -> e
    end
  end

  # Minimal XML parse of the SignedIdentifiers document. Azure emits one
  # <SignedIdentifier> per id with <Id>, and optionally <AccessPolicy> with
  # <Start>/<Expiry>/<Permission>. Regex-parse only this bounded grammar.
  def parse_signed_identifiers(body) when body in [nil, ""] do
    {:ok, []}
  end

  def parse_signed_identifiers(body) when is_binary(body) do
    id_blocks = Regex.scan(~r/<SignedIdentifier>(.*?)<\/SignedIdentifier>/s, body)

    identifiers =
      Enum.map(id_blocks, fn [_, block] ->
        id =
          case Regex.run(~r/<Id>(.*?)<\/Id>/s, block) do
            [_, v] -> v
            _ -> ""
          end

        {start, expiry, perms} =
          case Regex.run(~r/<AccessPolicy>(.*?)<\/AccessPolicy>/s, block) do
            [_, ap] ->
              {xml_text(ap, "Start"), xml_text(ap, "Expiry"),
               xml_text(ap, "Permission")}

            _ ->
              {nil, nil, nil}
          end

        %{"id" => id, "start" => start, "expiry" => expiry, "permissions" => perms}
      end)

    with :ok <- check_acl_count(identifiers),
         :ok <- check_acl_permissions(identifiers) do
      {:ok, identifiers}
    end
  end

  def parse_signed_identifiers(_), do: {:error, 400, "InvalidXmlDocument", "Request body is not valid SignedIdentifiers XML."}

  defp check_acl_count(identifiers) when length(identifiers) <= @max_signed_identifiers, do: :ok

  defp check_acl_count(_),
    do: {:error, 400, "InvalidArgument", "Too many signed identifiers (max 5 per container)."}

  defp check_acl_permissions(identifiers) do
    bad =
      Enum.find(identifiers, fn idf ->
        perms = idf["permissions"]

        is_binary(perms) and perms != "" and
          not (perms |> String.graphemes() |> Enum.all?(&(&1 in @acl_permissions)))
      end)

    if bad,
      do: {:error, 400, "InvalidXmlDocument",
           "Invalid permission letter in SignedIdentifier AccessPolicy (allowed: r, a, c, w, d, l)."},
      else: :ok
  end

  defp xml_text(block, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, block) do
      [_, v] -> v
      _ -> nil
    end
  end

  @doc "Render the GET ?comp=acl SignedIdentifiers XML document."
  def acl_xml(identifiers) do
    inner =
      Enum.map(identifiers, fn idf ->
        policy =
          if idf["start"] || idf["expiry"] || idf["permissions"] do
            "<AccessPolicy>" <>
              (if idf["start"], do: "<Start>#{idf["start"]}</Start>", else: "") <>
              (if idf["expiry"], do: "<Expiry>#{idf["expiry"]}</Expiry>", else: "") <>
              (if idf["permissions"], do: "<Permission>#{idf["permissions"]}</Permission>", else: "") <>
              "</AccessPolicy>"
          else
            ""
          end

        "<SignedIdentifier><Id>#{xml_escape(idf["id"] || "")}</Id>#{policy}</SignedIdentifier>"
      end)
      |> Enum.join()

    "<?xml version=\"1.0\" encoding=\"utf-8\"?><SignedIdentifiers>#{inner}</SignedIdentifiers>"
  end

  # Compile-freeze unblock (lane verification/py, disclosed): the newer def
  # xml_escape/1 above covers this older private copy — the duplicate name
  # does not compile.

  @doc false
  def ensure_policy_table do
    if :ets.info(@policy_table) == :undefined do
      :ets.new(@policy_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  # Real Azure Storage answers x-ms-request-id with a dashed-36 RFC 4122 v4
  # GUID — same unified form as the ARM gateway and LA surface
  # (egress_router.ex generate_request_id/0; cross-court finding F1,
  # compliance lens-7 8th confirmation). Previously a 32-hex dialect pin.
  defp request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c4 = :erlang.band(c, 0x0FFF) + 0x4000
    d = :erlang.bor(:erlang.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c4,
      d,
      e
    ])
    |> IO.iodata_to_binary()
  end
end
