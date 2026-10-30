defmodule Smalt.DataPlane.Blob.Worm do
  @moduledoc """
  WORM / immutability-policy face of the Blob data plane: container
  immutability policy + legal hold CRUD, the container-WORM arm resolver
  (create/overwrite/delete), per-blob immutability (Premium 80/20),
  the serialized policy-row CAS, and the fail-closed invariant surface the
  `blob-worm` gate drives.

  Extracted verbatim from Smalt.DataPlane.BlobStorage (T09 blob split, lane
  L09); the facade defdelegates the public policy surface. The blob-worm
  invariant gate is this face's non-vacuity court.
  """

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.Store

  @policy_table :smalt_blob_policy

  # AR-WIRE-02 (carried with validate_period_days): OTP-29 range-guard
  # delegate - see the BlobStorage header comment for the pin history.
  defguardp int_in(x, lo, hi) when is_integer(x) and x >= lo and x <= hi

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
    now = BlobStorage.now_ms(opts)
    container_key = BlobStorage.container_key(account, container)

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

  @doc """
  PUT ?comp=immutabilityPolicy — sets or locks the container immutability policy.
  Locking requires `If-Match: "*"`. After lock, changing the policy → 409
  `ContainerLocked`. Stored in `:smalt_blob_policy`.
  """
  def set_immutability_policy(account, container, policy, headers \\ %{}, opts \\ []) do
    container_key = BlobStorage.container_key(account, container)
    now = BlobStorage.now_ms(opts)
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
        "x-ms-request-id" => BlobStorage.request_id(),
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

  @doc """
  DELETE ?comp=immutabilityPolicy — deletes an UNLOCKED container immutability
  policy (Azure Delete Immutability Policy). A LOCKED policy (still within
  retention) refuses 409 `ContainerLocked`; a missing policy is 404
  `ImmutabilityPolicyNotFound`. The read-check-write serializes through the
  Store CAS like set_immutability_policy/5 — never a stale write-back.
  """
  def delete_immutability_policy(account, container, _headers \\ %{}, opts \\ []) do
    container_key = BlobStorage.container_key(account, container)
    now = BlobStorage.now_ms(opts)
    ensure_policy_table()

    with {:ok, container_meta} <- fetch_container_meta(container_key),
         :ok <-
           cas_policy_row(container_key, fn existing ->
             with :ok <- refuse_if_locked(existing, container_meta, now) do
               if policy_present?(existing) do
                 # sibling keys (metadata, legal_hold) survive — delete only
                 # the immutability_policy key from the committed row.
                 {:ok, Map.delete(existing, "immutability_policy")}
               else
                 {:error, 404, "ImmutabilityPolicyNotFound",
                  "There is no immutability policy set on this container."}
               end
             else
               {:error, :locked} ->
                 {:error, 409, "ContainerLocked", locked_policy_message()}
             end
           end) do
      {:ok, 200,
       %{
         "x-ms-request-id" => BlobStorage.request_id(),
         "x-ms-version" => "2021-12-02"
       }, nil}
    else
      {:error, 404, code, msg} -> {:error, 404, code, msg}
      {:error, 409, code, msg} -> {:error, 409, code, msg}
      {:error, 500, code, msg} -> {:error, 500, code, msg}
    end
  end

  # R153: pure policy builder for the immutability write, run inside the CAS
  # closure against the freshly-read row. Preserves the pre-R153 semantics:
  # period_days falls back to the committed value, an explicit "until" => nil
  # falls through to the computed default, and the concurrent legal_hold field
  # is carried over from the row as read under serialization.
  def build_immutability_policy(existing, policy, now) do
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

  # Azure grammar: immutabilityPeriodSinceCreationInDays is an integer in
  # [0, 146000]; anything else is 400 InvalidXmlDocument (previously ANY value
  # was stored verbatim — negative days, binaries, 10^12 producing an
  # "until" in the year 2737909033).
  @max_retention_days 146_000

  # AR-WIRE-02 (IMPL-11): OTP-29 is_integer/3 range-guard head via the
  # module's int_in delegate — single guard, identical [0, @max_retention_days]
  # admission, 400 InvalidXmlDocument refusal unchanged.
  def validate_period_days(days)
       when int_in(days, 0, @max_retention_days),
       do: :ok

  def validate_period_days(_),
    do:
      {:error, 400, "InvalidXmlDocument",
       "immutabilityPeriodSinceCreationInDays must be an integer between 0 and 146000."}

  @doc """
  PUT/DELETE ?comp=legalhold — sets (`flag: true`) or clears (`flag: false`)
  the container legal hold. Stored in `:smalt_blob_policy`.
  """
  def set_legal_hold(account, container, flag, _headers \\ %{})

  def set_legal_hold(account, container, flag, _headers) when is_boolean(flag) do
    container_key = BlobStorage.container_key(account, container)
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
      # Real-Azure wire face (storage/legalhold@family-mismatch close): the
      # set/clear arm answers 200 with the x-ms-legal-hold response HEADER and
      # no JSON body; the boolean lives in the policy row (GET comp=legalhold
      # surfaces it as x-ms-legal-hold: true|false).
      {:ok, 200,
       %{
         "x-ms-request-id" => BlobStorage.request_id(),
         "x-ms-version" => "2021-12-02",
         "x-ms-legal-hold" => to_string(flag)
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

  def check_worm(container_meta, now) do
    if worm_blocked?(container_meta, "delete", now) do
      {:error, {:worm, blocker(fetch_policy(container_meta))}}
    else
      :ok
    end
  end

  # SHIM-COURT: verb-parameterized check_worm — resolves the caller's WORM
  # arm ("create" / "overwrite" / "delete") per the moduledoc convention.
  def check_worm_arm(container_meta, arm, now) do
    if worm_blocked?(container_meta, arm, now) do
      {:error, {:worm, blocker(fetch_policy(container_meta))}}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Per-blob immutability (Premium 80/20). Headers on Put Blob:
  #   x-ms-immutability-until-date   (HTTP-date; absence = no/cleared policy)
  #   x-ms-immutability-policy-mode  (Locked | Unlocked; default Unlocked)
  # Stored on the blob record as immutability_until (epoch ms) + mode. While
  # now <= until the blob refuses overwrite/delete (409 ContainerLocked),
  # unless the request EXTENDS the policy (request until >= stored until) or
  # CLEARS it (no immutability headers + stored mode Unlocked). The
  # container-level WORM check runs independently — the stricter policy wins.
  # ---------------------------------------------------------------------------

  @immutability_modes ~w(Locked Unlocked)

  # Parses request headers into `{:ok, imm | nil}` or
  # `{:error, 400, "InvalidHeaders", msg}`. `nil` means the request carries no
  # immutability headers (a clearing PUT on overwrite).
  def parse_blob_immutability(headers) do
    headers = headers || %{}
    until_raw = ConditionalHeaders.header(headers, "x-ms-immutability-until-date")
    mode_raw = ConditionalHeaders.header(headers, "x-ms-immutability-policy-mode")

    cond do
      is_nil(until_raw) and is_nil(mode_raw) ->
        {:ok, nil}

      is_nil(until_raw) ->
        {:error, 400, "InvalidHeaders",
         "x-ms-immutability-policy-mode requires x-ms-immutability-until-date."}

      true ->
        with {:ok, mode} <- validate_immutability_mode(mode_raw) do
          case parse_http_date_ms(until_raw) do
            {:ok, until_ms} -> {:ok, %{"immutability_until" => until_ms, "immutability_mode" => mode}}
            :error ->
              {:error, 400, "InvalidHeaderValue",
               "Value for x-ms-immutability-until-date is invalid (RFC 1123 HTTP-date expected)."}
          end
        end
    end
  end

  def validate_immutability_mode(nil), do: {:ok, "Unlocked"}

  def validate_immutability_mode(mode) when mode in @immutability_modes,
    do: {:ok, mode}

  def validate_immutability_mode(mode),
    do:
      {:error, 400, "InvalidHeaderValue",
       "Invalid x-ms-immutability-policy-mode: #{inspect(mode)}. Valid: Locked, Unlocked."}

  # RFC 1123 HTTP-date -> epoch ms (:httpd_util parses RFC 1123/850/asctime).
  def parse_http_date_ms(raw) when is_binary(raw) do
    case :httpd_util.convert_request_date(String.to_charlist(raw)) do
      {{y, mo, d}, {h, mi, s}} ->
        case DateTime.new(Date.new!(y, mo, d), Time.new!(h, mi, s), "Etc/UTC") do
          {:ok, dt} -> {:ok, DateTime.to_unix(dt, :millisecond)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_http_date_ms(_), do: :error

  # Overwrite gate. Refuses while the stored policy is active, except:
  #   * extension: the request carries an until-date >= the stored one
  #     (Azure permits extending, never shortening, a Locked policy)
  #   * clearing: the request carries NO immutability headers and the stored
  #     mode is Unlocked (the replace then omits the fields)
  def blob_immutability_refuses?(existing, req_imm, now) do
    case blob_immutability_active?(existing, now) do
      false ->
        false

      true ->
        cond do
          is_map(req_imm) and req_imm["immutability_until"] >= existing["immutability_until"] ->
            false

          is_nil(req_imm) and existing["immutability_mode"] == "Unlocked" ->
            false

          true ->
            true
        end
    end
  end

  def blob_immutability_active?(%{"immutability_until" => until} = _blob, now)
       when is_integer(until),
       do: now <= until

  def blob_immutability_active?(_blob, _now), do: false

  def blob_worm_message(%{"immutability_until" => until} = _blob) when is_integer(until) do
    until_iso =
      DateTime.from_unix!(until, :millisecond)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    "Blob modification refused: per-blob immutability policy is in effect until #{until_iso} (ContainerLocked)."
  end

  def blob_worm_message(_blob),
    do: "Blob modification refused: per-blob immutability policy is in effect (ContainerLocked)."

  # Delete arm — any active per-blob policy refuses (an Unlocked policy must
  # first be cleared by an overwrite PUT with cleared headers).
  def check_blob_worm(existing, now) do
    if blob_immutability_active?(existing, now) do
      {:error, {:blob_worm, blob_worm_message(existing)}}
    else
      :ok
    end
  end

  @doc false
  def with_immutability(blob, nil), do: Map.delete(blob, "immutability_until") |> Map.delete("immutability_mode")

  def with_immutability(blob, imm) when is_map(imm),
    do: Map.merge(blob, imm)

  # WORM block when a legal hold is set (never expires), or the immutability
  # policy is locked / container is immutable while retention is still live.
  # Once `now > created_at + retention_days` the container unlocks — except
  # for an active legal hold, which only an explicit release lifts.
  # Create arm ("create"): only a legal hold blocks NEW-blob creation
  # (R5); time-retention/immutable containers still accept new blobs,
  # matching the pre-existing retention-expiry test expectations.
  def worm_blocked?(container_meta, "create", _now) do
    legal_hold?(fetch_policy(container_meta))
  end

  def worm_blocked?(container_meta, _op, now) do
    policy = fetch_policy(container_meta)

    cond do
      legal_hold?(policy) -> true
      expired?(container_meta, now) -> false
      locked_policy?(policy) -> true
      # Azure parity (parity lane 2026-10-28, receipted against Azurite): a
      # container with NO legal hold and NO immutability policy is MUTABLE.
      # The removed legacy clause (`immutable == true and no policy`) locked
      # every SDK-created container — setMetadata/blob-delete answered 409
      # ContainerLocked with no hold set, where real Azure allows both.
      # WORM blocks only on an active hold or a locked policy; the
      # "immutable" container flag stays on the record but is inert for
      # blocking.
      true -> false
    end
  end

  # Retention expiry: now strictly past created_at + retention_days.
  # Legacy containers without created_at are conservatively never expired.
  def expired?(_container_meta, _now, created_at) when is_nil(created_at), do: false

  def expired?(container_meta, now, created_at) do
    now > created_at + retention_ms(container_meta)
  end

  def expired?(container_meta, now) do
    expired?(container_meta, now, Map.get(container_meta, "created_at"))
  end

  def retention_end_ms(container_meta) do
    case Map.get(container_meta, "created_at") do
      nil -> nil
      created_at -> created_at + retention_ms(container_meta)
    end
  end

  def retention_ms(container_meta) do
    Map.get(container_meta, "retention_days", 1095) * 86_400_000
  end

  def fetch_policy(container_meta) do
    ensure_policy_table()

    case Store.get(@policy_table, "#{container_meta["account"]}/#{container_meta["container"]}") do
      {:ok, p} -> p
      :error -> nil
    end
  end

  def policy_present?(nil), do: false
  def policy_present?(policy), do: Map.has_key?(policy, "immutability_policy")

  def legal_hold?(policy), do: !!policy && !!Map.get(policy, "legal_hold")

  def locked_policy?(nil), do: false

  def locked_policy?(policy) do
    case Map.get(policy, "immutability_policy") do
      %{"locked" => true} -> true
      _ -> false
    end
  end

  def blocker(policy) do
    cond do
      legal_hold?(policy) -> :legal_hold
      locked_policy?(policy) -> :locked_policy
      true -> :legacy_immutable
    end
  end

  def worm_message(container_meta, _now) do
    container_meta
    |> fetch_policy()
    |> blocker()
    |> worm_message_reason()
  end

  def worm_message_reason(:legal_hold),
    do: "Blob modification refused: container has an active legal hold (ContainerLocked)."

  def worm_message_reason(:locked_policy),
    do: "Blob modification refused: container immutability policy is locked (ContainerLocked)."

  def worm_message_reason(:legacy_immutable),
    do: "Blob modification refused: container policy enforces immutable WORM retention."

  def locked_policy_message,
    do: "Immutability policy is locked and can no longer be changed (ContainerLocked)."

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

  def cas_policy_row_loop(_container_key, _update_fn, 0) do
    {:error, 500, "OperationFailed", "policy row contention: update did not converge"}
  end

  def cas_policy_row_loop(container_key, update_fn, attempts) do
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
  def fetch_container_meta(container_key) do
    case Store.get(:smalt_blob_containers, container_key) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  def refuse_if_locked(existing, container_meta, now) do
    if locked_policy?(existing) and not expired?(container_meta, now) do
      {:error, :locked}
    else
      :ok
    end
  end

  def require_star_if_match_for_lock(headers, policy) do
    if Map.get(policy, "locked", false) do
      case ConditionalHeaders.header(headers || %{}, "if-match") do
        "*" -> :ok
        _ -> {:error, :if_match_required}
      end
    else
      :ok
    end
  end

  def put_in_worm_defaults(policy) do
    Map.put_new(policy, "immutability_policy", %{
      "locked" => false,
      "until" => nil,
      "period_days" => 0
    })
  end

  def default_until(days, now_ms) when is_integer(days) and days > 0 do
    DateTime.from_unix!(now_ms, :millisecond)
    |> DateTime.add(days * 86_400)
    |> DateTime.to_iso8601()
  end

  def default_until(_, _), do: nil

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
end
