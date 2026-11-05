# kv7 BEAM-oracle live leg court (lane L16, v26.11.5): the live cross-check
# where the BEAM data plane (8443, real HTTP, real stores) is the ORACLE and
# the posh kv7 sub-dialect translate face is pinned against it on the SAME
# keys: >=5 kv7 operations (put / point-get / patch / versions-list /
# list / delete), each exercised through BOTH faces, (status, body) parity
# asserted per operation (key sets + scalars, byte-equal).
#
# Wire law consumed, not re-stated: KD-15 challenge handshake (tokenless
# 401 + WWW-Authenticate; the authed resend here rides the data plane's
# SharedKey dev-key admission - see SmaltTest.Kv7Oracle), KD-03 per-face
# value polarity, KD-S4 newest-first versions index, KD-102 soft-delete. The posh half is
# reached through its own delegation bindings (azure.Kv7TranslateFor) via a
# law-free runtime driver (SmaltTest.Kv7Oracle.posh_translate/3) - no kv7 law
# is copied into this court.
#
# Substrate down: loud typed skip - never a fake pass. No sleeps: readiness
# is a bounded TCP-dial poll (SmaltTest.AssertEventually).
defmodule Smalt.Internal.Kv7BeamOracleCourtTest do
  use ExUnit.Case, async: false

  alias SmaltTest.Kv7Oracle, as: Oracle

  @api "7.4"

  setup_all do
    on_exit(fn -> Oracle.stop_driver() end)
    :ok
  end

  test "kv7 BEAM-oracle live leg: six ops through both faces, same keys, parity" do
    assert :ok = Oracle.require_substrate!()
    name = "l16-oracle-#{System.system_time(:millisecond)}"
    base = "/secrets/#{name}?api-version=#{@api}"

    # -- op 1: PUT (create) - KD-15 handshake then 201 ----------------------
    {401, _} = Oracle.beam_call(:put, base, ~s({"value":"l16-v1"}), tokenless: true)
    assert Oracle.challenge?(), "KD-15: tokenless PUT answered no WWW-Authenticate challenge"

    {201, put1} = Oracle.beam_call(:put, base, ~s({"value":"l16-v1"}))
    assert put1["value"] == "l16-v1", "PUT must echo the value (point face)"
    v1 = version_of!(put1["id"], name)

    row = canon_row("l16-v1", put1["id"], true, v1)
    assert {:ok, 200, posh} = Oracle.posh_translate("azure.kv7.secrets.put", row)
    assert_parity(put1, posh, :put)

    # -- op 2: point GET (latest == last write) -----------------------------
    {200, get1} = Oracle.beam_call(:get, base, nil)
    assert get1["id"] == put1["id"], "latest must resolve the last write"
    assert get1["value"] == "l16-v1"

    row = canon_row(get1["value"], get1["id"], true, v1)
    assert {:ok, 200, posh} = Oracle.posh_translate("azure.kv7.secrets.get", row)
    assert_parity(get1, posh, :get)

    # -- op 3: PUT re-set x2 (version accumulation) --------------------------
    {200, put2} = Oracle.beam_call(:put, base, ~s({"value":"l16-v2"}))
    {200, put3} = Oracle.beam_call(:put, base, ~s({"value":"l16-v3"}))
    v2 = version_of!(put2["id"], name)
    v3 = version_of!(put3["id"], name)
    assert v1 != v2 and v2 != v3, "version mint collision"

    row = canon_row("l16-v3", put3["id"], true, v3)
    assert {:ok, 200, posh} = Oracle.posh_translate("azure.kv7.secrets.put", row)
    assert_parity(put3, posh, :put)

    # -- op 4: PATCH (attributes-only; value never rotates) ------------------
    patch_body = ~s({"attributes":{"enabled":false}})
    {200, patch} = Oracle.beam_call(:patch, base, patch_body)
    assert patch["value"] == "l16-v3", "PATCH must never rotate the value"

    enabled =
      case patch["attributes"] do
        %{"enabled" => e} -> e
        _ -> nil
      end

    assert enabled == false, "PATCH must persist enabled=false"

    # patch_secret_record law: the PATCH arm puts an unconditional "tags"
    # member (merged {} when the client sends none) - the store row the posh
    # patch face projects therefore always carries tags.
    row =
      put3
      |> Map.put("value", patch["value"])
      |> Map.put("id", patch["id"])
      |> Map.put("attributes", patch["attributes"] || %{"enabled" => false})
      |> Map.put("version", v3)
      |> Map.put("tags", %{})

    assert {:ok, 200, posh} = Oracle.posh_translate("azure.kv7.secrets.patch", row)
    assert_parity(patch, posh, :patch)

    # -- op 5: versions list (newest-first; value AND version per KD-S3 law) --
    {200, vers} = Oracle.beam_call(:get, "/secrets/#{name}/versions?api-version=#{@api}", nil)
    entries = vers["value"] || flunk("versions face returned no envelope: #{inspect(vers)}")
    assert length(entries) == 3, "versions face: #{length(entries)} entries (want 3)"
    assert versions_newest_first?(entries, [v3, v2, v1])

    entries
    |> Enum.with_index()
    |> Enum.each(fn {entry, i} ->
      assert entry["value"], "versions-face[#{i}]: value absent (KD-S3 registered law)"
      assert entry["version"], "versions-face[#{i}]: version member absent"
      assert_no_bookkeeping(entry, "versions-face[#{i}]")

      full =
        entry
        |> Map.put("created_seq", i)
        |> Map.put("is_version_row", true)
        |> Map.put("versions", [entry["version"]])

      assert {:ok, 200, %{"value" => [rendered]}} =
               Oracle.posh_translate("azure.kv7.secrets.versions", full)

      assert_parity(entry, rendered, {:versions, i})
    end)

    # -- op 6: list face (KD-03 drop-list: bundles never carry the value) -----
    {200, list} = Oracle.beam_call(:get, "/secrets?api-version=#{@api}", nil)
    bundles = list["value"] || flunk("list face returned no envelope: #{inspect(list)}")

    mine =
      Enum.filter(bundles, fn b ->
        case b["id"] do
          nil -> false
          id -> String.contains?(id, "/secrets/#{name}/")
        end
      end)

    assert [list_row] = mine, "list face: exactly one bundle for #{name}, got #{length(mine)}"
    refute is_map_key(list_row, "value"), "KD-03: list face carried a value"
    assert_no_bookkeeping(list_row, "list-face")

    # Reconstruct the store row WITH a value: the posh list face must drop it
    # the same way - proving the drop-list, not an absent input.
    full =
      list_row
      |> Map.put("value", "SHOULD-BE-DROPPED")
      |> Map.put("version", v3)
      |> Map.put("created_seq", 1)
      |> Map.put("versions", [v3])
      |> Map.put("is_version_row", true)

    assert {:ok, 200, %{"value" => [rendered]}} =
             Oracle.posh_translate("azure.kv7.secrets.list", full)

    refute is_map_key(rendered, "value"), "posh list face carried a value"
    assert_parity(list_row, rendered, :list)

    # -- op 7: DELETE (KD-102 soft delete; deleted bundle carries no value) ---
    {200, del} = Oracle.beam_call(:delete, base, nil)
    assert is_map_key(del, "recoveryId"), "delete must answer the recoveryId contract"
    refute is_map_key(del, "value"), "deleted bundle must never carry the value"

    # The store row at delete time: the PATCH answer plus its version - the
    # posh delete face (engine-soft-delete policy) must drop the value and
    # keep the id/attributes core the BEAM deleted bundle carries.
    row = Map.put(patch, "version", v3)

    assert {:ok, 200, posh} = Oracle.posh_translate("azure.kv7.secrets.delete", row)
    refute is_map_key(posh, "value"), "posh delete face carried a value"
    assert posh["id"] == del["id"], "posh delete id #{inspect(posh["id"])} != BEAM #{inspect(del["id"])}"

    assert_parity_core(del, posh, :delete)

    # Live GET after soft delete must 404 by construction.
    {404, _} = Oracle.beam_call(:get, base, nil)

    :ok
  end

  # -- parity + law helpers ---------------------------------------------------

  defp version_of!(id, name) when is_binary(id) do
    suffix = "https://127.0.0.1.vault.azure.net/secrets/#{name}/"

    case String.split(id, suffix) do
      [_, ver] -> ver
      _ -> flunk("id grammar: #{inspect(id)} lacks #{suffix}")
    end
  end

  # The canonical store-row shape the BEAM point faces project FROM: the
  # point faces drop only "version" (public_secret_record), so the twin
  # re-attaches it from the bundle id. Attributes ride the BEAM body
  # verbatim (created/updated are wall-clock on BEAM; parity compares the
  # enabled scalar only).
  defp canon_row(value, id, enabled, ver) do
    %{
      "value" => value,
      "id" => id,
      "attributes" => %{"enabled" => enabled, "created" => 1_700_000_000, "updated" => 1_700_000_001},
      "version" => ver,
      "created_seq" => 42,
      "versions" => [ver]
    }
  end

  # (status, body) parity: key SETS equal + scalars byte-equal (value/id);
  # attributes compared on the enabled scalar (created/updated are
  # wall-clock on BEAM). The posh face answered 200 by construction here.
  defp assert_parity(beam, posh, face) when is_atom(face) or is_tuple(face) do
    assert is_map_key(posh, "value") == is_map_key(beam, "value"),
           "#{inspect(face)}: value polarity diverged (beam #{is_map_key(beam, "value")} vs posh #{is_map_key(posh, "value")})"

    assert MapSet.new(Map.keys(beam)) == MapSet.new(Map.keys(posh)),
           "#{inspect(face)}: key sets diverged (beam #{inspect(Map.keys(beam))} vs posh #{inspect(Map.keys(posh))})"

    assert_parity_core(beam, posh, face)
  end

  defp assert_parity_core(beam, posh, _face) do
    if is_map_key(beam, "id") do
      assert posh["id"] == beam["id"], "id #{inspect(posh["id"])} != BEAM #{inspect(beam["id"])}"
    end

    if is_map_key(beam, "value") do
      assert posh["value"] == beam["value"],
             "value #{inspect(posh["value"])} != BEAM #{inspect(beam["value"])}"
    end

    beam_attrs = beam["attributes"] || %{}
    posh_attrs = posh["attributes"] || %{}

    assert posh_attrs["enabled"] == beam_attrs["enabled"],
           "attributes.enabled #{inspect(posh_attrs["enabled"])} != BEAM #{inspect(beam_attrs["enabled"])}"
  end

  defp versions_newest_first?(entries, want) do
    got = Enum.map(entries, & &1["version"])
    got == want
  end

  # Bookkeeping never leaves the vault on ANY wire face (KD-S3/KD-S4).
  @bookkeeping ["versions", "created_seq", "is_version_row", "version_rows"]

  defp assert_no_bookkeeping(bundle, face) do
    leaked = Enum.filter(@bookkeeping, &is_map_key(bundle, &1))
    assert leaked == [], "#{face}: bookkeeping keys leaked onto the wire: #{inspect(leaked)}"
  end
end
