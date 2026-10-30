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

  ## Per-blob immutability (Premium surface, honest 80/20)

  `x-ms-immutability-until-date` (HTTP-date) + `x-ms-immutability-policy-mode`
  (`Locked`/`Unlocked`) request headers on Put Blob store a per-blob policy
  (`immutability_until` epoch-ms / `immutability_mode` on the blob record).
  While `now <= until` the blob refuses overwrite and delete with 409
  `ContainerLocked`; the stricter of container-level and blob-level policy
  wins (both checks run). An **Unlocked** policy is cleared by an overwrite
  PUT with cleared immutability headers; a **Locked** policy may only be
  extended (request until-date >= stored until-date) and otherwise refuses
  until the date passes. Mode-without-date is 400 `InvalidHeaders`; date
  without mode defaults to `Unlocked` (Azure parity).
  """
  # T09 blob split (lane L09): the engine faces now live in Blob.Core /
  # Blob.Worm / Blob.Leases / Blob.Website; this module is the thin facade
  # (defdelegates preserve the public API; wire behavior unchanged).
  alias Smalt.DataPlane.Blob.Website
  alias Smalt.DataPlane.Blob.Leases
  alias Smalt.DataPlane.Blob.Worm
  alias Smalt.DataPlane.Blob.Core
  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.Store


  # D127 (ARM teardown cascade): deleting a storageAccount (directly or via
  # RG delete) must not orphan data-plane rows. Blob tables key rows as
  # "account/container" and "account/container/blob", so an account-prefix
  # sweep ("acct/") across every blob table removes the account's whole
  # data-plane footprint. Lazily-created tables (:smalt_blob_blocks,
  # :smalt_blob_snapshots) may not be booted — guard with :ets.info. The
  # per-container DELETE route stays a product-faithful gap (D127 scopes the
  # cascade to account teardown, not container teardown).
  # WORM/policy face: extracted verbatim to Smalt.DataPlane.Blob.Worm (T09
  # blob split, lane L09). Facade keeps the public wire API byte-identical;
  # blob courts + the blob-worm invariant gate gate parity.
  defdelegate policy_state(account, container, opts \\ []), to: Worm
  defdelegate set_immutability_policy(account, container, policy, headers \\ %{}, opts \\ []), to: Worm
  defdelegate delete_immutability_policy(account, container, headers \\ %{}, opts \\ []), to: Worm
  defdelegate set_legal_hold(account, container, flag, headers \\ %{}), to: Worm
  defdelegate get_policy(account, container), to: Worm
  defdelegate cas_policy_row(container_key, update_fn), to: Worm
  defdelegate ensure_policy_table(), to: Worm
  defdelegate with_immutability(blob, imm), to: Worm


  # Lease/ETag/conditional face: extracted verbatim to Smalt.DataPlane.Blob.Leases
  # (T09 blob split, lane L09). Facade keeps the public wire API byte-identical;
  # blob courts gate parity.
  defdelegate lease_container(account, container, action, headers \\ %{}, opts \\ []), to: Leases
  defdelegate lease_blob(account, container, blob_name, action, headers \\ %{}, opts \\ []), to: Leases
  defdelegate lease_blob_snapshot(account, container, blob_name, ts, action, headers \\ %{}, opts \\ []), to: Leases
  defdelegate get_blob_range(account, container, blob_name, range_header \\ []), to: Leases
  defdelegate get_blob_conditional(account, container, blob_name, headers), to: Leases


  # Static-website face: extracted verbatim to Smalt.DataPlane.Blob.Website
  # (T09 blob split, lane L09). The facade keeps the public wire API
  # byte-identical; the existing blob courts gate parity.
  # ---------------------------------------------------------------------------

  @doc "The static-website content container (Azure parity: fixed name)."
  defdelegate static_website_container(), to: Website

  @doc false
  defdelegate ensure_service_props_table(), to: Website

  @doc """
  Set Blob Service Properties (w6av): parse the request XML and store the
  StaticWebsite block per account. Returns :ok or
  {:error, 400, "InvalidXmlDocument", msg}. A valid body WITHOUT a
  StaticWebsite block disables the website (Azure parity: PUT clears what
  it omits).
  """
  defdelegate set_service_properties(account, xml_body), to: Website

  @doc "Stored StaticWebsite props for account, or nil (unset)."
  defdelegate website_props(account), to: Website

  @doc """
  Get Blob Service Properties XML: StorageServiceProperties with the stored
  StaticWebsite block (element omitted when unset - real Azure omits the
  block when the website was never enabled).
  """
  defdelegate service_properties_xml(account), to: Website

  @doc """
  Serve-decision for the static website face (w6av): :pass (website off /
  container not the web container / query present - normal blob handling),
  {:serve, blob, content_type}, {:serve_404, blob}, or {:plain_404, msg}.
  """
  defdelegate static_website_serve(account, container, blob, query_params), to: Website

  # ---------------------------------------------------------------------------
  # Core face: extracted verbatim to Smalt.DataPlane.Blob.Core (T09 blob split,
  # lane L09). Facade keeps the public wire API byte-identical; the existing
  # blob courts + engine probe gate parity.
  # ---------------------------------------------------------------------------

  defdelegate drop_account_data(account), to: Core
  defdelegate create_container(account, container, opts \\ %{}), to: Core
  defdelegate delete_container(account, container, opts \\ []), to: Core
  defdelegate check_maxresults(raw), to: Core
  defdelegate put_blob(account, container, blob_name, content, headers \\ %{}, opts \\ []), to: Core
  defdelegate ensure_block_table(), to: Core
  defdelegate stage_block(account, container, blob_name, block_id, content, headers \\ %{}, opts \\ []), to: Core
  defdelegate commit_block_list(account, container, blob_name, refs, headers \\ %{}, opts \\ []), to: Core
  defdelegate get_block_list(account, container, blob_name), to: Core
  defdelegate block_list_xml(committed, uncommitted), to: Core
  defdelegate parse_block_list_xml(body), to: Core
  defdelegate delete_blob(account, container, blob_name, headers \\ %{}, opts \\ []), to: Core
  defdelegate tier_wire(blob), to: Core
  defdelegate set_blob_tier(account, container, blob_name, tier, opts \\ []), to: Core
  defdelegate copy_blob(account, container, blob_name, copy_source, headers \\ %{}, opts \\ []), to: Core
  defdelegate copy_wire(blob), to: Core
  defdelegate ensure_snapshot_table(), to: Core
  defdelegate snapshot_blob(account, container, blob_name, headers \\ %{}, opts \\ []), to: Core
  defdelegate get_blob_snapshot(account, container, blob_name, ts), to: Core
  defdelegate list_snapshots(account, container, blob_name), to: Core
  defdelegate get_snapshot_record(snap_key), to: Core
  defdelegate put_snapshot_record(snap_key, snap), to: Core
  defdelegate check_content(content), to: Core
  defdelegate get_blob(account, container, blob_name), to: Core
  defdelegate set_blob_metadata(account, container, blob_name, metadata, headers \\ %{}), to: Core
  defdelegate append_block(account, container, blob_name, content, headers \\ %{}, opts \\ []), to: Core
  defdelegate put_page(account, container, blob_name, content, headers \\ %{}, opts \\ []), to: Core
  defdelegate set_blob_http_headers(account, container, blob_name, headers \\ %{}, opts \\ []), to: Core
  defdelegate put_blob_record(blob_key, blob), to: Core
  defdelegate blob_metadata(blob), to: Core
  defdelegate list_blobs_xml(account, container, opts \\ %{}), to: Core
  defdelegate rfc1123(iso), to: Core
  defdelegate xml_escape(value), to: Core
  defdelegate xml_text(block, tag), to: Core
  defdelegate get_acl(account, container), to: Core
  defdelegate set_container_acl(account, container, body, headers \\ %{}, opts \\ []), to: Core
  defdelegate parse_signed_identifiers(body), to: Core
  defdelegate acl_xml(identifiers), to: Core
  defdelegate now_ms(opts), to: Core
  defdelegate container_key(account, container), to: Core
  defdelegate request_id(), to: Core
  defdelegate header_value(headers, name), to: Core

end
