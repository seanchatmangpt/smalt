defmodule Smalt.DataPlane.Blob.Leases do
  @moduledoc """
  Lease / ETag / conditional-header face of the Blob data plane:
  container lease, base-blob lease, per-snapshot lease (KD-107),
  the lease-id/ETag/conditional request-header helpers, ranged GET
  (RFC 9110 Range grammar) and conditional read engines, and the
  delete-on-lease guard.

  Extracted verbatim from Smalt.DataPlane.BlobStorage (T09 blob split,
  lane L09); the facade defdelegates the public lease/read surface, so
  wire behavior is unchanged and the existing blob courts gate parity.
  """

  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.Store

  # AR-WIRE-02 (carried with the parse_range family): OTP-29 range-guard
  # delegate - see the BlobStorage header comment for the pin history.
  defguardp int_in(x, lo, hi) when is_integer(x) and x >= lo and x <= hi

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
    BlobStorage.ensure_snapshot_table()
    snap_key = {"#{account}/#{container}/#{blob_name}", ts}
    now = BlobStorage.now_ms(opts)
    lease_id = BlobStorage.header_value(headers, "x-ms-lease-id")

    with [{{_k, _ts}, snap}] <- BlobStorage.get_snapshot_record(snap_key) do
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

              BlobStorage.put_snapshot_record(snap_key, Map.put(snap, "lease", new_lease))
              {:ok, 201, snapshot_lease_headers(snap, id), nil}
            end
          end

        :renew ->
          with :ok <- require_lease(snap, lease_id, now),
               {:ok, seconds} <- lease_duration(headers) do
            lease = extend_lease(Map.get(snap, "lease"), now, seconds)
            snap = Map.put(snap, "lease", lease)
            BlobStorage.put_snapshot_record(snap_key, snap)
            {:ok, 200, snapshot_lease_headers(snap, Map.get(lease, "id")), nil}
          end

        :release ->
          with :ok <- require_lease(snap, lease_id, now, :leased_or_broken) do
            BlobStorage.put_snapshot_record(snap_key, Map.delete(snap, "lease"))
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
            BlobStorage.put_snapshot_record(snap_key, snap)

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

  # Snapshot lease success headers derive from the FROZEN blob record (quoted
  # etag + RFC 1123 Last-Modified from "last_modified"), not the container
  # record lease_success_headers/2 reads.
  def snapshot_lease_headers(snap, lease_id) do
    {:ok, lm_dt, _} = DateTime.from_iso8601(snap["last_modified"])
    lm = Calendar.strftime(lm_dt, "%a, %d %b %Y %H:%M:%S GMT")

    base = %{
      "etag" => snap["etag"],
      "last-modified" => lm,
      "x-ms-request-id" => BlobStorage.request_id(),
      "x-ms-version" => "2021-12-02"
    }

    if lease_id, do: Map.put(base, "x-ms-lease-id", lease_id), else: base
  end

  # ---------------------------------------------------------------------------
  # Parity lane 2026-10-28 (receipted against Azurite; see
  # parity/COVERAGE_VS_TOPAZ.md): base-blob lease (comp=lease without
  # sharesnapshot), Append Block, Put Page, and Set Blob HTTP Headers.
  # Same state machines / envelope discipline as the snapshot lease and
  # container lease arms above.
  # ---------------------------------------------------------------------------

  @doc """
  Lease Blob (`PUT /{container}/{blob}?comp=lease` with `x-ms-lease-action`).
  Acquire/renew/release/break on the BASE blob record — the snapshot variant
  (`lease_blob_snapshot/6`) keeps its per-snapshot lease namespace.
  """
  @spec lease_blob(String.t(), String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, non_neg_integer(), map(), nil}
          | {:error, non_neg_integer() | :worm_locked, String.t() | nil, String.t() | nil}
  def lease_blob(account, container, blob_name, action, headers \\ %{}, opts \\ []) do
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = BlobStorage.now_ms(opts)
    lease_id = BlobStorage.header_value(headers, "x-ms-lease-id")

    with {:ok, blob} <- Store.get(:smalt_blobs, blob_key) do
      case normalize_action(action) do
        :acquire ->
          with :ok <- validate_proposed_lease_id(headers),
               {:ok, seconds} <- lease_duration(headers) do
            if lease_active?(Map.get(blob, "lease"), now) do
              {:error, 409, "LeaseAlreadyPresent", "There is already a lease present on the blob."}
            else
              id = acquire_lease_id(headers)
              expires = if seconds == :infinity, do: :infinity, else: now + seconds * 1000

              new_lease = %{
                "id" => id,
                "state" => "leased",
                "expires_at" => expires,
                "duration" => seconds
              }

              BlobStorage.put_blob_record(blob_key, Map.put(blob, "lease", new_lease))
              {:ok, 201, blob_lease_headers(blob, id), nil}
            end
          end

        :renew ->
          with :ok <- require_lease(blob, lease_id, now),
               {:ok, seconds} <- lease_duration(headers) do
            lease = extend_lease(Map.get(blob, "lease"), now, seconds)
            blob = Map.put(blob, "lease", lease)
            BlobStorage.put_blob_record(blob_key, blob)
            {:ok, 200, blob_lease_headers(blob, Map.get(lease, "id")), nil}
          end

        :release ->
          with :ok <- require_lease(blob, lease_id, now, :leased_or_broken) do
            blob = Map.delete(blob, "lease")
            BlobStorage.put_blob_record(blob_key, blob)
            {:ok, 200, blob_lease_headers(blob, nil), nil}
          end

        :break ->
          with :ok <- require_lease(blob, lease_id, now, :leased_or_broken) do
            lease = Map.get(blob, "lease")

            remaining =
              case Map.get(lease, "expires_at") do
                :infinity -> 0
                ms when is_integer(ms) -> max(0, div(ms - now, 1000))
                _ -> 0
              end

            blob = Map.put(blob, "lease", Map.merge(lease, %{"state" => "broken", "expires_at" => nil}))
            BlobStorage.put_blob_record(blob_key, blob)

            {:ok, 202,
             Map.put(blob_lease_headers(blob, Map.get(lease, "id")), "x-ms-lease-time", Integer.to_string(remaining)),
             nil}
          end

        other when other in [nil, :error] ->
          {:error, 400, "InvalidQueryParameterValue",
           "Invalid or missing x-ms-lease-action (expected acquire|renew|release|break)."}
      end
    else
      :error -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
    end
  end

  def blob_lease_headers(blob, lease_id) do
    base = %{
      "etag" => blob["etag"],
      "last-modified" => BlobStorage.rfc1123(blob["last_modified"]),
      "x-ms-request-id" => BlobStorage.request_id(),
      "x-ms-version" => "2021-12-02"
    }

    if is_binary(lease_id) and lease_id != "" do
      Map.put(base, "x-ms-lease-id", lease_id)
    else
      base
    end
  end

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
    container_key = BlobStorage.container_key(account, container)
    now = BlobStorage.now_ms(opts)
    lease_id = BlobStorage.header_value(headers, "x-ms-lease-id")

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

            lease_remaining =
              case Map.get(lease, "expires_at") do
                :infinity -> 0
                ms when is_integer(ms) -> max(0, div(ms - now, 1000))
                _ -> 0
              end

            # w6ak audit fix: honor x-ms-lease-break-period (0..60s) — Azure
            # LeaseTime = min(specified break period, remaining lease time).
            # Previously the header was ignored and LeaseTime was the raw
            # remaining lease time.
            remaining =
              case Integer.parse(BlobStorage.header_value(headers, "x-ms-lease-break-period") || "") do
                {p, ""} when p >= 0 and p <= 60 -> min(p, lease_remaining)
                _ -> lease_remaining
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

  def normalize_action(a) when is_binary(a) do
    case String.downcase(a) do
      a when a in @lease_actions -> String.to_existing_atom(a)
      _ -> :error
    end
  end

  def normalize_action(_), do: :error

  # NOTE: lease-id presence rules — release/break/renew REQUIRE a lease id
  # header; acquire does not. Mismatch is 409 LeaseIdMismatchWithLeaseOperation.
  # Renew requires an ACTIVE lease; release/break accept a lease in either
  # the leased OR broken state (Azure parity: break leaves the lease
  # breakable-releaseable — refusing release after break deadlocks the lease).
  def require_lease(record, lease_id, now, mode \\ :active) do
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

  def lease_present?(lease) when is_map(lease), do: Map.get(lease, "state") in ["leased", "broken"]
  def lease_present?(_), do: false

  def lease_active?(nil, _now), do: false

  def lease_active?(lease, now) when is_map(lease) do
    Map.get(lease, "state") == "leased" and
      (Map.get(lease, "expires_at") == :infinity or
         (is_integer(Map.get(lease, "expires_at")) and Map.get(lease, "expires_at") > now))
  end

  # x-ms-lease-duration: "-1" (infinite) or 15..60 seconds (Azure Lease
  # Container REST: "A non-infinite lease can be between 15 and 60 seconds");
  # absent defaults to infinite. Anything else is a typed 400
  # InvalidHeaderValue. (w6ak audit: previously any n>0 was admitted — a 5s
  # lease landed 201 where real Azure answers 400.)
  def lease_duration(headers) do
    case BlobStorage.header_value(headers, "x-ms-lease-duration") do
      nil ->
        {:ok, :infinity}

      "-1" ->
        {:ok, :infinity}

      raw when is_binary(raw) ->
        case Integer.parse(raw) do
          {n, ""} when n >= 15 and n <= 60 -> {:ok, n}
          _ ->
            {:error, 400, "InvalidHeaderValue",
             "x-ms-lease-duration must be -1 or an integer between 15 and 60 seconds."}
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

  def validate_proposed_lease_id(headers) do
    case BlobStorage.header_value(headers, "x-ms-proposed-lease-id") do
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

  def acquire_lease_id(headers) do
    case BlobStorage.header_value(headers, "x-ms-proposed-lease-id") do
      nil -> BlobStorage.request_id()
      id -> id
    end
  end

  def extend_lease(lease, _now, :infinity), do: Map.put(lease, "expires_at", :infinity)

  def extend_lease(lease, now, n) when is_integer(n),
    do: Map.put(lease, "expires_at", now + n * 1000)

  def put_lease(container_key, record, lease) do
    record = Map.put(record, "lease", lease)
    Store.put(:smalt_blob_containers, container_key, record)
  end

  # Standard success header set for lease ops (Azure shape): quoted ETag +
  # RFC 1123 Last-Modified from the container record, x-ms-lease-id when one
  # applies, request-id + version stamped by blob_route entry.
  def lease_success_headers(record, lease_id) do
    {:ok, created_dt, _} = DateTime.from_iso8601(record["created"])
    lm = Calendar.strftime(created_dt, "%a, %d %b %Y %H:%M:%S GMT")

    base = %{
      "etag" => container_etag_value(record),
      "last-modified" => lm,
      "x-ms-request-id" => BlobStorage.request_id(),
      "x-ms-version" => "2021-12-02"
    }

    if lease_id, do: Map.put(base, "x-ms-lease-id", lease_id), else: base
  end

  # BlobService.container_etag/1 is the canonical quoted container ETag
  # (md5 of account/container/created_at); reuse, never re-derive.
  def container_etag_value(record), do: BlobService.container_etag(record)

  # Azure Delete Container conflict: an ACTIVE lease (leased + unexpired)
  # refuses 409 ContainerLeased unless the request carries the matching
  # x-ms-lease-id. A broken or absent lease never blocks.
  def check_lease_on_delete(container_meta, headers, now) do
    lease = Map.get(container_meta, "lease")

    if lease_active?(lease, now) do
      supplied = BlobStorage.header_value(headers, "x-ms-lease-id")

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
  def modified_since?(last_modified, if_modified_since) do
    case {http_date_to_epoch(if_modified_since), iso8601_to_epoch(last_modified)} do
      {{ims, _raw}, {lm, _}} when ims != nil and lm != nil -> lm > ims
      _ -> true
    end
  end

  def http_date_to_epoch(raw) do
    case :httpd_util.convert_request_date(to_charlist(raw)) do
      {{_y, _m, _d}, {_h, _mi, _s}} = cal ->
        # Same scale as iso8601_to_epoch: Unix seconds. The Gregorian-to-Unix
        # offset (62167219200 s) is a constant, not a wall-clock read.
        {:calendar.datetime_to_gregorian_seconds(cal) - 62_167_219_200, raw}

      _ ->
        {nil, raw}
    end
  end

  def iso8601_to_epoch(raw) do
    case DateTime.from_iso8601(raw || "") do
      {:ok, dt, _off} ->
        {DateTime.to_unix(dt, :second), raw}

      {:error, _} ->
        {nil, raw}
    end
  end

  def conditional_etag_match?("*", _etag), do: true

  def conditional_etag_match?(value, etag) when is_binary(value) do
    String.split(value, ",") |> Enum.map(&String.trim/1) |> Enum.member?(etag)
  end

  def conditional_etag_match?(_, _), do: false

  def parse_range(nil, _total), do: {:ok, nil}

  def parse_range(header, total) when is_binary(header) do
    case Regex.run(~r/^bytes=(\d*)-(\d*)$/, String.trim(header)) do
      [_, first, last] -> parse_range_spec(first, last, total)
      _ -> {:ok, nil}
    end
  end

  # OTP-29 TOOLCHAIN FLOOR: is_integer/3 range guards below are OTP-29-only
  # (compile-refused on OTP <= 28). Repo standard toolchain: OTP 29 (TOOLUP).
  @max_range_guard_int 9_007_199_254_740_991

  # Bounds validation via OTP-29 is_integer/3 guard heads (AR-WIRE-02).
  # Digit strings come from the parse_range regex (\d*, non-negative), so
  # only the upper bound is live in each head; the trailing is_integer/1
  # clause in each family is the bignum-above-guard-ceiling arm with
  # IDENTICAL semantics to the bounded head (same statuses, AR-WIRE-02).
  def parse_range_spec("", "", _total), do: {:ok, nil}

  # bytes=a- : f in [0, total-1] serves f..total-1; f >= total is 416.
  def parse_range_spec(first, "", total) do
    range_from(String.to_integer(first), total)
  end

  # bytes=-suffix : last in [1, total] -> start total-last; last > total
  # clamps start to 0; last <= 0 is 416.
  def parse_range_spec("", last, total) do
    suffix_range(String.to_integer(last), total)
  end

  def parse_range_spec(first, last, total) do
    span_range(String.to_integer(first), String.to_integer(last), total)
  end


  def range_from(f, total) when int_in(f, 0, total - 1), do: {:ok, {f, total - 1}}

  def range_from(f, total) when int_in(f, total, @max_range_guard_int), do: :unsatisfiable

  # Bignum beyond the guard literal ceiling: f >= total necessarily.
  def range_from(f, _total) when is_integer(f) and f > @max_range_guard_int,
    do: :unsatisfiable

  def suffix_range(last, total) when int_in(last, 1, total), do: {:ok, {total - last, total - 1}}

  def suffix_range(last, total) when int_in(last, total + 1, @max_range_guard_int),
    do: {:ok, {0, total - 1}}

  # Bignum beyond the guard ceiling: start clamps to 0 (max(total-last, 0)).
  def suffix_range(last, total) when is_integer(last) and last > @max_range_guard_int,
    do: {:ok, {0, total - 1}}

  # last <= 0 (e.g. the "0" digit arm): 416, exactly as pre-conversion.
  def suffix_range(last, _total) when is_integer(last) and last < 1, do: :unsatisfiable

  # bytes=a-b : f in [0, total-1] and l < f is malformed-per-RFC (ignored,
  # full body); otherwise serve f..min(l, total-1). f >= total is 416.
  def span_range(f, l, total) when int_in(f, 0, total - 1) and l < f, do: {:ok, nil}

  def span_range(f, l, total) when int_in(f, 0, total - 1),
    do: {:ok, {f, min(l, total - 1)}}

  def span_range(f, l, total) when int_in(f, total, @max_range_guard_int) and is_integer(l),
    do: :unsatisfiable

  # Bignum beyond the guard ceiling: f >= total necessarily.
  def span_range(f, _l, _total) when is_integer(f) and f > @max_range_guard_int,
    do: :unsatisfiable

  def mismatched_if_match?(headers, current_etag) do
    case ConditionalHeaders.header(headers || %{}, "if-match") do
      nil -> false
      _value -> ConditionalHeaders.evaluate(headers, current_etag) == {:halt, 412}
    end
  end

  def if_none_match_star?(headers) do
    case ConditionalHeaders.header(headers || %{}, "if-none-match") do
      nil -> false
      "*" -> true
      _ -> false
    end
  end

  def check_if_match(headers, current_etag) do
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
  def check_if_none_match(headers) do
    case if_none_match_star?(headers) do
      true -> {:error, {:precondition}}
      false -> :ok
    end
  end

  def precondition_message,
    do: "The condition specified using HTTP conditional header(s) is not met."
end
