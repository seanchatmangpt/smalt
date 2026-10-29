# T-02 witness (resource pre-seeding, integration tier): `mix smalt.seed` corpus
# ingestion into the ARM store.
#
# Chicago discipline: real Store rows (`:smalt_resources`, lowercased-id key
# law), the real mix task module invoked via run/1 (no shell-out, no mocks),
# and a real ARM router dispatch for the GET-compat face. The corpus is a
# temp file under System.tmp_dir!/1 — the same shape a developer exports from
# real Azure with `az resource list --output json` + `az resource show`.
#
#   seed   -> Store.get returns the record, provisioningState defaulted
#   dry-run-> would-be ids printed, nothing written
#   re-seed-> byte-identical rows (double seed = no-op)
#   missing file / malformed JSON / malformed entry -> typed error exit,
#             never a raise, and never a partial seed
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.SeedTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Test

  alias Smalt.Store

  @api_version "2021-04-01"
  @sub "sub-t02"
  @rg "rg-t02"
  @sa_id "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/stseedt02"
  @kv_id "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/kvseedt02"
  @ns_id "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.ServiceBus/namespaces/nsseedt02"

  setup do
    corpus_path =
      Path.join(System.tmp_dir!(), "smalt-t02-corpus-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(corpus_path)

      Enum.each([@sa_id, @kv_id, @ns_id], fn id ->
        Store.delete(:smalt_resources, String.downcase(id))
      end)
    end)

    %{corpus_path: corpus_path}
  end

  defp arm_req(method, path) do
    url = "#{path}?api-version=#{@api_version}"

    Smalt.ArmGateway.Router.call(
      Plug.Conn.fetch_query_params(conn(method, url)),
      []
    )
  end

  defp write_corpus(corpus_path, entries),
    do: File.write!(corpus_path, Jason.encode!(entries))

  # The exact shape `az resource show` emits: no provisioningState inside
  # properties (the PUT path defaults it at persist time; so must the seed).
  defp storage_entry do
    %{
      "id" => @sa_id,
      "name" => "stseedt02",
      "type" => "Microsoft.Storage/storageAccounts",
      "location" => "westus2",
      "sku" => %{"name" => "Standard_LRS", "tier" => "Standard"},
      "kind" => "StorageV2",
      "properties" => %{
        "supportsHttpsTrafficOnly" => true,
        "allowBlobPublicAccess" => true,
        "minimumTlsVersion" => "TLS1_2"
      }
    }
  end

  defp vault_entry do
    %{
      "id" => @kv_id,
      "name" => "kvseedt02",
      "type" => "Microsoft.KeyVault/vaults",
      "location" => "eastus",
      "tags" => %{"env" => "t02"},
      "properties" => %{
        "sku" => %{"family" => "A", "name" => "standard"},
        "tenantId" => "tenant-t02",
        "enableSoftDelete" => true,
        "provisioningState" => "Succeeded"
      }
    }
  end

  defp namespace_entry do
    %{
      "id" => @ns_id,
      "name" => "nsseedt02",
      "type" => "Microsoft.ServiceBus/namespaces",
      "location" => "eastus"
    }
  end

  # -- happy path: seeded rows + GET parity with hand-PUT ------------------------

  test "seed hydrates the ARM store; provisioningState defaulted; GET parity with hand-PUT", %{
    corpus_path: path
  } do
    write_corpus(path, [storage_entry()])

    assert :ok = Mix.Tasks.Smalt.Seed.run(["--file", path])

    # Store row conventions (sb_arm_rules_test law): the KEY is the downcased
    # resource id; the wire "id" keeps the corpus casing.
    key = String.downcase(@sa_id)
    assert {:ok, record} = Store.get(:smalt_resources, key)
    assert record["id"] == @sa_id
    assert record["name"] == "stseedt02"
    assert record["type"] == "Microsoft.Storage/storageAccounts"
    assert record["location"] == "westus2"
    # Default application: the corpus omitted provisioningState, the seed
    # applies the same persist-time default the PUT paths apply.
    assert record["properties"]["provisioningState"] == "Succeeded"
    assert record["properties"]["supportsHttpsTrafficOnly"] == true

    # GET-compat face: in-process ARM dispatch renders the seeded row
    # verbatim — the same 200 echo a hand-PUT resource answers with.
    get = arm_req(:get, @sa_id)
    assert get.status == 200

    body = Jason.decode!(get.resp_body)
    assert body["id"] == @sa_id
    assert body["name"] == "stseedt02"
    assert body["location"] == "westus2"
    assert body["properties"]["provisioningState"] == "Succeeded"
    assert body["properties"]["supportsHttpsTrafficOnly"] == true
  end

  test "explicit corpus members pass through verbatim; absent properties default wholesale", %{
    corpus_path: path
  } do
    write_corpus(path, [vault_entry(), namespace_entry()])

    assert :ok = Mix.Tasks.Smalt.Seed.run(["--file", path])

    assert {:ok, vault} = Store.get(:smalt_resources, String.downcase(@kv_id))
    # provisioningState present in the corpus -> preserved, not re-defaulted.
    assert vault["properties"]["provisioningState"] == "Succeeded"
    assert vault["properties"]["enableSoftDelete"] == true
    assert vault["tags"] == %{"env" => "t02"}

    # A corpus entry with no properties at all still lands the defaulted map.
    assert {:ok, ns} = Store.get(:smalt_resources, String.downcase(@ns_id))
    assert ns["type"] == "Microsoft.ServiceBus/namespaces"
    assert ns["location"] == "eastus"
    assert ns["properties"] == %{"provisioningState" => "Succeeded"}
  end

  # -- dry-run -------------------------------------------------------------------

  test "dry-run prints the would-be ids and writes nothing", %{corpus_path: path} do
    write_corpus(path, [storage_entry(), vault_entry()])

    assert Store.get(:smalt_resources, String.downcase(@sa_id)) == :error
    assert Store.get(:smalt_resources, String.downcase(@kv_id)) == :error

    output =
      capture_io(fn ->
        assert :ok = Mix.Tasks.Smalt.Seed.run(["--file", path, "--dry-run"])
      end)

    assert output =~ @sa_id
    assert output =~ @kv_id
    assert output =~ "DRY-RUN"

    # Still nothing written.
    assert Store.get(:smalt_resources, String.downcase(@sa_id)) == :error
    assert Store.get(:smalt_resources, String.downcase(@kv_id)) == :error
  end

  # -- idempotency ---------------------------------------------------------------

  test "re-seed is idempotent: double seed leaves byte-identical rows", %{corpus_path: path} do
    write_corpus(path, [storage_entry()])

    assert :ok = Mix.Tasks.Smalt.Seed.run(["--file", path])
    {:ok, first} = Store.get(:smalt_resources, String.downcase(@sa_id))

    assert :ok = Mix.Tasks.Smalt.Seed.run(["--file", path])
    {:ok, second} = Store.get(:smalt_resources, String.downcase(@sa_id))

    assert first == second
    assert :erlang.term_to_binary(first) == :erlang.term_to_binary(second)
  end

  # -- typed error faces (no raise, no partial seed) ------------------------------

  test "missing corpus file -> typed error exit, never a raise" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "smalt-t02-absent-#{System.unique_integer([:positive])}.json"
      )

    assert catch_exit(Mix.Tasks.Smalt.Seed.run(["--file", missing])) == {:shutdown, 1}
  end

  test "malformed JSON -> typed error exit, nothing written", %{corpus_path: path} do
    File.write!(path, "{not json")

    assert catch_exit(Mix.Tasks.Smalt.Seed.run(["--file", path])) == {:shutdown, 1}
    assert Store.get(:smalt_resources, String.downcase(@sa_id)) == :error
  end

  test "malformed entry -> typed error exit and NO partial seed (all-or-nothing)", %{
    corpus_path: path
  } do
    write_corpus(path, [storage_entry(), %{"id" => 42, "name" => "n", "type" => "t"}])

    assert catch_exit(Mix.Tasks.Smalt.Seed.run(["--file", path])) == {:shutdown, 1}
    # The VALID entry was not written either — a corrupt corpus hydrates nothing.
    assert Store.get(:smalt_resources, String.downcase(@sa_id)) == :error
  end
end
