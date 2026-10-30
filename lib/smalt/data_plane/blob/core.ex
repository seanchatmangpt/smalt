defmodule Smalt.DataPlane.Blob.Core do
  @moduledoc """
  Container/blob CRUD + properties engine of the Blob data plane (T09 blob split,
  lane L09): containers, block staging/commit, snapshots, metadata/append/page,
  listing XML, ACL, and the shared engine helpers (clock, keys, request-id,
  RFC-1123, header lookups, XML escaping). Extracted verbatim from
  Smalt.DataPlane.BlobStorage; the facade defdelegates this face's public API.
  """

  alias Smalt.DataPlane.Blob.Leases
  alias Smalt.DataPlane.Blob.Worm
  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.Store

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
         :ok <- Worm.check_worm(container_meta, now),
         :ok <- Leases.check_lease_on_delete(container_meta, opts, now) do
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
        {:error, 409, "ContainerLocked", Worm.worm_message_reason(reason)}

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
    # Azure parity (w6av): "$web" is the special static-website container —
    # exempt from the 3-63 lowercase rule (real Azure auto-creates it on
    # enable and it is not addressable via the name-rule REST path).
    if name == "$web" or
         not (name == "" or byte_size(name) > 63 or not Regex.match?(@container_name_re, name)) do
      :ok
    else
      {:error, 400, "InvalidResourceName",
       "The specified container name is invalid (3-63 bytes, lowercase letters, digits and dashes, starting and ending alphanumeric)."}
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
        # KD-COVERS: KD-135 — engine default follows wire parity: a container
        # is writable unless explicitly created immutable (official SDK
        # delete-on-default-container depends on it).
        "immutable" => Map.get(opts, "immutable", false),
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
         :ok <- check_metadata_names(headers),
         {:ok, imm} <- Worm.parse_blob_immutability(headers) do
      case Store.get(:smalt_blobs, blob_key) do
        {:ok, existing} ->
          cond do
            Worm.worm_blocked?(container_meta, "overwrite", now) ->
              {:error, :worm_locked, Worm.worm_message(container_meta, now)}

            Worm.blob_immutability_refuses?(existing, imm, now) ->
              {:error, :worm_locked, Worm.blob_worm_message(existing)}

            Leases.mismatched_if_match?(headers, existing["etag"]) ->
              {:error, :precondition_failed, Leases.precondition_message()}

            # Azure parity (cycle-21): If-None-Match: * refuses overwrite of
            # an existing blob (412) — previously silently ignored, so a
            # conditional-create raced through as an unconditional overwrite.
            Leases.if_none_match_star?(headers) ->
              {:error, :precondition_failed, Leases.precondition_message()}

            # AZB-06: the If-Match replace runs as a Store CAS
            # (compare_and_swap/4 inside the Store GenServer), so N concurrent
            # replaces with the same If-Match etag yield EXACTLY one
            # winner (200/201) and N-1 precondition losers (412) — the old
            # read-then-write TOCTOU could admit multiple winners.
            true ->
              cas_replace(account, container, blob_name, content, headers, existing, imm)
          end

        :error ->
          cond do
            # Azure parity (R5: audit A1 defect, create-with-hold): a legal
            # hold blocks NEW-blob creation with 409 ContainerLocked, same
            # as overwrite. Previously the create arm skipped the WORM check
            # entirely. Time-based immutability alone does not block create
            # (real Azure permits new-blob writes into retention containers),
            # so the create arm consults the hold-scoped predicate clause.
            Worm.worm_blocked?(container_meta, "create", now) ->
              {:error, :worm_locked, Worm.worm_message(container_meta, now)}

            # Azure parity (cycle-21): If-Match on a NON-EXISTENT blob is
            # 412 (a precondition on a resource that does not exist fails).
            # Previously the create path skipped all preconditions, so
            # If-Match: * created unconditionally.
            ConditionalHeaders.header(headers, "if-match") != nil ->
              {:error, :precondition_failed, Leases.precondition_message()}

            true ->
              store_blob(account, container, blob_name, content, headers, imm)
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

  # KD-COVERS: KD-141 — invalid x-ms-meta-* name/value answers 400
  # InvalidMetadata (real Azure parity), never a crash-class 500 or a
  # stored row.
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

      # Azure Put Block returns x-ms-request-server-encrypted: true on the
      # 201 (write-op encryption confirmation; emulator data plane is
      # server-encrypted by construction).
      {:ok, 201,
       %{
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02",
         "x-ms-request-server-encrypted" => "true"
       }}
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
    cond do
      block_id == "" or byte_size(block_id) > 64 ->
        {:error, 400, "InvalidQueryParameterValue", "The blockid must be between 1 and 64 bytes."}

      # Azure parity (parity lane 2026-10-28): real storage requires the
      # blockid to be valid base64 (Azurite receipts 400 on non-base64 ids;
      # smalt previously accepted and staged them).
      match?({:ok, _}, Base.decode64(block_id)) ->
        :ok

      true ->
        {:error, 400, "InvalidQueryParameterValue",
         "The blockid must be a valid base64-encoded string."}
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
         {:ok, imm} <- Worm.parse_blob_immutability(headers),
         {:ok, blocks} <- resolve_refs(refs, account, container, blob_name) do
      cond do
        # SHIM-COURT / KD-COVERS: KD-52 — existence-scoped WORM arm (parity
        # with put_blob): a legal hold blocks BOTH overwrite and create, but
        # time-retention only blocks overwrite of an existing blob (a new
        # blob commit under an unlocked/retention container is 201, R5).
        Worm.worm_blocked?(
          container_meta,
          if(existing_blob?(blob_key), do: "overwrite", else: "create"),
          now
        ) ->
          {:error, :worm_locked, Worm.worm_message(container_meta, now)}

        Leases.mismatched_if_match?(headers, committed_etag(blob_key)) ->
          {:error, :precondition_failed, Leases.precondition_message()}

        Leases.if_none_match_star?(headers) and existing_blob?(blob_key) ->
          {:error, :precondition_failed, Leases.precondition_message()}

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

          {:ok, blob} = store_blob(account, container, blob_name, content, headers, imm)

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
             "x-ms-version" => "2021-12-02",
             "x-ms-request-server-encrypted" => "true"
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
  # Public (T09 split): case-insensitive header lookup shared with Blob.Leases.
  @doc false
  def header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  def header_value(_, _), do: nil

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
         :ok <- Worm.check_worm(container_meta, now),
         :ok <- Worm.check_blob_worm(existing, now),
         :ok <- Leases.check_if_match(headers, existing["etag"]),
         :ok <- Leases.check_if_none_match(headers),
         # Azure parity (parity lane 2026-10-28, receipted vs Azurite): a blob
         # WITH snapshots refuses plain Delete (409 SnapshotsPresent) unless
         # x-ms-delete-snapshots names an include/only option.
         :ok <- check_snapshots_on_delete(blob_key, headers) do
      Store.delete(:smalt_blobs, blob_key)

      {:ok, 202, %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02"}, nil}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :not_found} -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", Worm.worm_message_reason(reason)}
      {:error, {:blob_worm, msg}} -> {:error, 409, "ContainerLocked", msg}
      {:error, {:precondition}} -> {:error, 412, "PreconditionFailed", Leases.precondition_message()}
      {:error, {:snapshots_present}} ->
        {:error, 409, "SnapshotsPresent",
         "This operation is not permitted while the blob has snapshots."}
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
  # Azure parity: Get Blob / Get Blob Properties echo the stored access tier
  # as x-ms-access-tier on block blobs that carry one (w6e, batch lane —
  # the batch Set Tier sub-request stores it; the wire must be able to read
  # it back). Empty list when the blob has no stored tier.
  def tier_wire(%{"access_tier" => tier} = _blob) when is_binary(tier) do
    [{"x-ms-access-tier", tier}]
  end

  def tier_wire(_blob), do: []

  def set_blob_tier(account, container, blob_name, tier, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         # SHIM-COURT / KD-COVERS: KD-52 — Set Blob Tier mutates the stored
         # blob, so it rides the "overwrite"-arm WORM check (legal hold,
         # locked policy, or unexpired retention -> 409 ContainerLocked).
         :ok <- Worm.check_worm_arm(container_meta, "overwrite", now),
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
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", Worm.worm_message_reason(reason)}
    end
  end

  # BK-132 (corpus triage): Sync Copy Blob — Put Blob From URL wire shape
  # (`PUT /{c}/{b}` + `x-ms-copy-source`, az `storage blob copy start
  # --requires-sync`). Previously MISSING: the header was ignored and the
  # (usually empty) PUT body was stored as the destination content.
  @doc """
  Sync Copy Blob (`PUT /{c}/{b}` + `x-ms-copy-source`). Copies the source
  blob's content and headers to the destination, then stores the copy-status
  record. Destination WORM/precondition rules ride put_blob/6 unchanged.

  Returns:

    * `{:ok, 202, headers, nil}` — Azure Put Blob From URL parity (202, never 201)
    * `{:error, 404, ...}` source/dest missing, `{:error, 409, ...}` dest WORM
  """
  def copy_blob(account, container, blob_name, copy_source, headers \\ %{}, opts \\ []) do
    dest_key = "#{account}/#{container}/#{blob_name}"

    with {:ok, src_account, src_container, src_blob} <- parse_copy_source(copy_source),
         {:ok, src} <- blob_or_404("#{src_account}/#{src_container}/#{src_blob}") do
      case put_blob(account, container, blob_name, src["content"], headers, opts) do
        {:ok, blob} ->
          copy_id = request_id()
          now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

          updated =
            blob
            |> Map.put("copy_id", copy_id)
            |> Map.put("copy_source", copy_source)
            |> Map.put("copy_status", "success")
            |> Map.put("copy_completion_time", now)

          Store.put(:smalt_blobs, dest_key, updated)
          Smalt.Store.DetsMirror.sync_write(:smalt_blobs)

          {:ok, 202,
           %{
             "x-ms-copy-id" => copy_id,
             "x-ms-copy-status" => "success",
             "x-ms-copy-completion-time" => now,
             "x-ms-version" => "2021-12-02",
             "x-ms-request-id" => request_id()
           }, nil}

        {:error, _kind, msg} = err ->
          _ = msg
          err
      end
    else
      {:error, :not_found} -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
    end
  end

  # x-ms-copy-source arrives as an absolute URL (az/SDK shape:
  # `https://host/{acct}/{cont}/{blob}`) or a path. Same-host cross-account
  # resolves by path segments.
  defp parse_copy_source(copy_source) when is_binary(copy_source) do
    case URI.parse(copy_source) do
      %URI{path: path} when is_binary(path) and path != "" ->
        case path |> String.trim_leading("/") |> String.split("/", parts: 3) do
          [acct, cont, blob] -> {:ok, acct, cont, blob}
          _ -> {:error, 400, "InvalidHeaderValue", "Invalid x-ms-copy-source URL."}
        end

      _ ->
        {:error, 400, "InvalidHeaderValue", "Invalid x-ms-copy-source URL."}
    end
  end

  defp parse_copy_source(_), do: {:error, 400, "InvalidHeaderValue", "Missing x-ms-copy-source."}

  # Azure parity: Get Blob / Get Blob Properties echo the last copy as
  # x-ms-copy-* headers. Empty list when the blob carries no copy record.
  def copy_wire(%{"copy_id" => id} = blob) when is_binary(id) do
    [
      {"x-ms-copy-id", id},
      {"x-ms-copy-status", blob["copy_status"] || "success"},
      {"x-ms-copy-source", blob["copy_source"] || ""},
      {"x-ms-copy-completion-time", blob["copy_completion_time"] || ""}
    ]
  end

  def copy_wire(_blob), do: []

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
         :ok <- Worm.check_worm_arm(container_meta, "create", now),
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
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", Worm.worm_message_reason(reason)}
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

  # Public (T09 split): raw snapshot-row accessor for Blob.Leases (the
  # snapshot lease state machine matches on the raw :ets.lookup list shape).
  @doc false
  def get_snapshot_record(snap_key) do
    ensure_snapshot_table()

    :ets.lookup(@snapshot_table, snap_key)
  end


  # Public (T09 split): snapshot-row write shared with Blob.Leases. No logic change.
  @doc false
  def put_snapshot_record(snap_key, snap) do
    :ets.insert(@snapshot_table, {snap_key, snap})
  end

  # Delete Blob with snapshots present: Azure answers 409 SnapshotsPresent
  # unless x-ms-delete-snapshots is "include" or "only" (then the snapshots go
  # with the base blob). Table-absent-safe (no snapshots ever created).
  # NOTE: this helper MUST live below the `@snapshot_table` attribute
  # definition — module attributes resolve in file order, and an earlier
  # placement silently expands to nil (the T-17 defect: `:ets.info(nil)`
  # answers :undefined, so the gate short-circuited to :ok).
  defp check_snapshots_on_delete(blob_key, headers) do
    if :ets.info(@snapshot_table) == :undefined do
      :ok
    else
      case :ets.match(@snapshot_table, {{blob_key, :_}, :_}) do
        [] ->
          :ok

        _snapshots ->
          case header_value(headers, "x-ms-delete-snapshots") do
            option when option in ["include", "only"] ->
              for {{k, ts}, _snap} <- :ets.match_object(@snapshot_table, {{blob_key, :_}, :_}) do
                :ets.delete(@snapshot_table, {k, ts})
              end

              :ok

            _ ->
              {:error, {:snapshots_present}}
          end
      end
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
           if(Worm.worm_blocked?(container_meta, "overwrite", now),
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
         "x-ms-version" => "2021-12-02",
         "x-ms-request-server-encrypted" => "true"
       }}
    else
      # SHIM-COURT: WORM-blocked metadata mutation -> 409 ContainerLocked
      # (same tuple shape as put_blob / commit_block_list).
      {:worm, container_meta} -> {:error, :worm_locked, Worm.worm_message(container_meta, now)}
      :error -> {:error, 404, "BlobNotFound", "Blob not found."}
      {:error, 400, _code, _msg} = invalid -> invalid
    end
  end

  @doc """
  Append Block (`PUT /{container}/{blob}?comp=appendblock`). Appends the raw
  request bytes to the blob content, rotating etag + last-modified. WORM
  "overwrite"-class gate applies (hold/locked policy refuses).
  """
  @spec append_block(String.t(), String.t(), String.t(), binary(), map(), keyword()) ::
          {:ok, 201, map(), nil} | {:error, term(), term(), term() | nil}
  def append_block(account, container, blob_name, content, _headers \\ %{}, opts \\ []) do
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, "#{account}/#{container}"),
         {:ok, blob} <- Store.get(:smalt_blobs, blob_key),
         :ok <-
           if(Worm.worm_blocked?(container_meta, "overwrite", now),
             do: {:worm, container_meta},
             else: :ok
           ) do
      prev = blob["content"] || ""
      offset = byte_size(prev)
      next_content = prev <> content

      with :ok <- check_put_size(next_content) do
        etag = "\"#{:crypto.hash(:md5, next_content) |> Base.encode16(case: :lower)}\""
        now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

        updated =
          %{blob | "content" => next_content}
          |> Map.put("content_length", byte_size(next_content))
          |> Map.put("etag", etag)
          |> Map.put("last_modified", now_iso)

        put_blob_record(blob_key, updated)

        {:ok, 201,
         %{
           "etag" => etag,
           "last-modified" => rfc1123(now_iso),
           "x-ms-append-offset" => Integer.to_string(offset),
           "x-ms-blob-committed-block-count" => "1",
           "x-ms-request-id" => request_id(),
           "x-ms-version" => "2021-12-02"
         }, nil}
      end
    else
      {:worm, container_meta} -> {:error, :worm_locked, nil, Worm.worm_message(container_meta, now)}
      :error -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
    end
  end

  @doc """
  Put Page (`PUT /{container}/{blob}?comp=page&x-ms-range=bytes=a-b`). Writes
  the request bytes into the 512-aligned range, zero-padding growth. Response
  201 carries `x-ms-blob-sequence-number`.
  """
  @spec put_page(String.t(), String.t(), String.t(), binary(), map(), keyword()) ::
          {:ok, 201, map(), nil} | {:error, term(), term(), term() | nil}
  def put_page(account, container, blob_name, content, headers \\ %{}, opts \\ []) do
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)
    range = header_value(headers, "x-ms-range") || header_value(headers, "range") || ""

    with {:ok, first, last} <- parse_page_range(range),
         {:ok, container_meta} <- Store.get(:smalt_blob_containers, "#{account}/#{container}"),
         {:ok, blob} <- Store.get(:smalt_blobs, blob_key),
         :ok <- check_page_alignment(first, last, byte_size(content)),
         :ok <-
           if(Worm.worm_blocked?(container_meta, "overwrite", now),
             do: {:worm, container_meta},
             else: :ok
           ) do
      prev = blob["content"] || ""
      total = max(byte_size(prev), last + 1)
      padded = pad_zeros(prev, total)
      next_content = overwrite_range(padded, first, content)
      etag = "\"#{:crypto.hash(:md5, next_content) |> Base.encode16(case: :lower)}\""
      now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

      updated =
        %{blob | "content" => next_content}
        |> Map.put("content_length", byte_size(next_content))
        |> Map.put("etag", etag)
        |> Map.put("last_modified", now_iso)

      put_blob_record(blob_key, updated)

      {:ok, 201,
       %{
         "etag" => etag,
         "last-modified" => rfc1123(now_iso),
         "x-ms-blob-sequence-number" => "1",
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02"
       }, nil}
    else
      {:worm, container_meta} -> {:error, :worm_locked, nil, Worm.worm_message(container_meta, now)}
      {:error, 400, code, msg} -> {:error, 400, code, msg}
      :error -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
    end
  end

  @doc """
  Set Blob HTTP Headers (`PUT /{container}/{blob}?comp=properties`). Reads the
  `x-ms-blob-content-*` request headers into the stored blob headers — a
  header ABSENT from the request REMOVES the stored value (Azure semantics);
  rotates etag + last-modified; answers 200 with the new etag.
  """
  @blob_content_header_keys ~w(x-ms-blob-content-cache-control x-ms-blob-content-disposition x-ms-blob-content-encoding x-ms-blob-content-language x-ms-blob-content-md5 x-ms-blob-content-type)

  @spec set_blob_http_headers(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, 200, map(), nil} | {:error, 404, String.t(), String.t()}
  def set_blob_http_headers(account, container, blob_name, headers \\ %{}, _opts \\ []) do
    blob_key = "#{account}/#{container}/#{blob_name}"

    with {:ok, blob} <- Store.get(:smalt_blobs, blob_key) do
      stored = blob["headers"] || %{}
      cleaned = Map.drop(stored, @blob_content_header_keys)
      incoming = Map.take(headers, @blob_content_header_keys)
      now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
      new_etag = metadata_etag(blob["etag"], incoming, now_iso)

      updated =
        %{blob | "headers" => Map.merge(cleaned, incoming)}
        |> Map.put("etag", new_etag)
        |> Map.put("last_modified", now_iso)

      put_blob_record(blob_key, updated)

      {:ok, 200,
       %{
         "etag" => new_etag,
         "last-modified" => rfc1123(now_iso),
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02"
       }, nil}
    else
      :error -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
    end
  end

  # Public (T09 split): durable blob-row write shared with Blob.Leases. No logic change.
  @doc false
  def put_blob_record(blob_key, blob) do
    Store.put(:smalt_blobs, blob_key, blob)
    Smalt.Store.DetsMirror.sync_write(:smalt_blobs)
  end

  # "bytes=first-last" (inclusive). Azure requires the range for Put Page.
  defp parse_page_range("bytes=" <> spec) do
    case String.split(spec, "-") do
      [a, b] ->
        with {first, ""} <- Integer.parse(a),
             {last, ""} <- Integer.parse(b),
             true <- first >= 0 and last >= first do
          {:ok, first, last}
        else
          _ -> {:error, 400, "InvalidHeaderValue", "The x-ms-range value is invalid."}
        end

      _ ->
        {:error, 400, "InvalidHeaderValue", "The x-ms-range value is invalid."}
    end
  end

  defp parse_page_range(_),
    do: {:error, 400, "MissingRequiredHeader", "x-ms-range is required for Put Page."}

  defp check_page_alignment(first, last, size) do
    if rem(first, 512) == 0 and rem(last + 1, 512) == 0 and size == last - first + 1 do
      :ok
    else
      {:error, 400, "InvalidHeaderValue",
       "The page range must be 512-byte aligned and match the content length."}
    end
  end

  defp pad_zeros(bin, total) when byte_size(bin) >= total, do: bin

  defp pad_zeros(bin, total),
    do: bin <> :binary.copy(<<0>>, total - byte_size(bin))

  defp overwrite_range(bin, at, replacement) do
    <<head::binary-size(^at), _::binary>> = bin
    tail_skip = at + byte_size(replacement)
    <<_::binary-size(^tail_skip), tail::binary>> = bin
    head <> replacement <> tail
  end

  # SHIM-COURT: metadata-set etag = MD5 of (stored etag, metadata, timestamp,
  # monotonic counter) — always distinct from the body-hash etag, even if the
  # same metadata is set twice.
  defp metadata_etag(prev_etag, metadata, now) do
    counter = System.unique_integer([:monotonic])

    BlobService.storage_etag(prev_etag <> inspect(metadata) <> now <> Integer.to_string(counter))
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
        <Prefix>#{xml_escape(prefix)}</Prefix>#{delimiter_xml}
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
      <Prefix>#{xml_escape(prefix)}</Prefix>#{delimiter_xml}
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
            <BlobType>BlockBlob</BlobType>
            <Content-Type>#{xml_escape(blob_content_type(b))}</Content-Type>
            <LeaseStatus>unlocked</LeaseStatus>
            <LeaseState>available</LeaseState>
            <Last-Modified>#{xml_escape(rfc1123(b["last_modified"]))}</Last-Modified>
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
            <BlobType>BlockBlob</BlobType>
            <Last-Modified>#{xml_escape(rfc1123(snap["last_modified"]))}</Last-Modified>
          </Properties>
        </Blob>
        """
      end)
      |> Enum.join("")
    else
      ""
    end
  end

  # KD-107 (wave-3): List Blobs <Last-Modified> is an RFC-1123 date on the
  # Azure wire contract ("Mon, 20 Oct 2026 08:54:30 GMT"); stored records keep
  # ISO-8601 internally (also the snapshot ETS key), so format at render.
  # KD-COVERS: KD-02 — List Blobs BlobProperties carries Content-Type
  # (from the stored Put-Blob headers; octet-stream fallback), LeaseStatus
  # and LeaseState, completing the Azure BlobProperties set alongside the
  # already-landed BlobType + RFC-1123 Last-Modified.
  defp blob_content_type(b) do
    case (b["headers"] || %{}) |> Map.new(fn {k, v} -> {String.downcase(k), v} end)
         |> Map.get("content-type") do
      nil -> "application/octet-stream"
      ct -> ct
    end
  end

  # Public (T09 split): RFC-1123 formatter shared with Blob.Leases. No logic change.
  @doc false
  def rfc1123(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} -> Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
      _ -> iso
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

  # Azure parity (cycle-34, List Blobs include=metadata): user metadata rides
  # x-ms-meta-* on the stored headers; when the request includes metadata the
  # listing emits a <Metadata> element per blob. Values go through the same
  # xml_escape (hostile & < > " entity-escaped; control chars are refused at
  # PUT by the InvalidMetadata fence). Only the exact "metadata" include
  # token enables it; the exact "snapshots" token additionally decorates
  # snapshot rows (KD-107 RAISE, snapshots_xml/3); versions/tags remain
  # admitted-but-undecorated.
  defp blob_metadata_xml(_b, false), do: ""
  defp blob_metadata_xml(_b, nil), do: ""

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

  defp store_blob(account, container, blob_name, content, headers, imm) do
    # KD-COVERS: KD-146 — blob etag mints route through BlobService.storage_etag/1
    # (quoted `0x` + 16 hex, Azure contract shape) instead of bare 32-hex md5.
    etag = BlobService.storage_etag(content)

    blob =
      %{
        "name" => blob_name,
        "content" => content,
        "content_length" => byte_size(content),
        "etag" => etag,
        "last_modified" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "headers" => headers
      }
      |> Worm.with_immutability(imm)

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
  defp cas_replace(account, container, blob_name, content, headers, expected, imm) do
    # KD-COVERS: KD-146 — blob etag mints route through BlobService.storage_etag/1
    # (quoted `0x` + 16 hex, Azure contract shape) instead of bare 32-hex md5.
    etag = BlobService.storage_etag(content)
    blob_key = "#{account}/#{container}/#{blob_name}"

    blob =
      %{
        "name" => blob_name,
        "content" => content,
        "content_length" => byte_size(content),
        "etag" => etag,
        "last_modified" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "headers" => headers
      }
      |> Worm.with_immutability(imm)

    case Store.compare_and_swap(:smalt_blobs, blob_key, expected, blob) do
      :ok ->
        Smalt.Store.DetsMirror.sync_write(:smalt_blobs)
        {:ok, blob}

      {:error, :conflict} ->
        case Store.get(:smalt_blobs, blob_key) do
          {:ok, current} ->
            if Leases.mismatched_if_match?(headers, current["etag"]) do
              {:error, :precondition_failed, Leases.precondition_message()}
            else
              cas_replace(account, container, blob_name, content, headers, current, imm)
            end

          # Deleted concurrently while we held a stale expect — an If-Match
          # precondition on a resource that no longer exists fails (cycle-21).
          :error ->
            {:error, :precondition_failed, Leases.precondition_message()}
        end
    end
  end

  # Public (T09 split): clock shared with Blob.Worm. No logic change.
  @doc false
  def now_ms(opts) when is_list(opts) do
    Keyword.get(opts, :now_ms) || System.os_time(:millisecond)
  end

  @doc false
  def now_ms(opts) when is_map(opts), do: now_ms(Enum.to_list(opts))

  defp blob_or_404(blob_key) do
    case Store.get(:smalt_blobs, blob_key) do
      {:ok, blob} -> {:ok, blob}
      :error -> {:error, :not_found}
    end
  end

  # Public (T09 split): key builder shared with Blob.Worm. No logic change.
  @doc false
  def container_key(account, container), do: account <> "/" <> container

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
         "etag" => Leases.container_etag_value(record),
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

  # Public (T09 blob split, lane L09): shared XML tag extractor - the
  # container ACL parser here and the Blob.Website service-properties parser
  # both read tags through this bounded-regex form. No logic change.
  @doc false
  def xml_text(block, tag) do
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

  # Real Azure Storage answers x-ms-request-id with a dashed-36 RFC 4122 v4
  # GUID — same unified form as the ARM gateway and LA surface
  # (egress_router.ex generate_request_id/0; cross-court finding F1,
  # compliance lens-7 8th confirmation). Previously a 32-hex dialect pin.
  # Public (T09 split): request-id mint shared with Blob.Worm. No logic change.
  @doc false
  def request_id do
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
