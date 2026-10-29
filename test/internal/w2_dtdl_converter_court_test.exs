defmodule Smalt.DTDL.W2CourtTest do
  @moduledoc """
  W2 DTDL→RDF/SHACL converter court (tier2-scout §2 falsifier).

  A real 3-node DTDL v3 model (Thermostat / Device / Building, the Building
  carrying a Thermostat Component and a Device-targeted Relationship) converts
  → compiles via LawCompiler.compile_all/1 → twin telemetry JSON evaluates
  through the compiled guards. Malformed DTDL refuses typed.
  """
  use ExUnit.Case, async: false

  alias Smalt.DTDL
  alias Smalt.POWL2.LawCompiler

  @moduletag :w2_dtdl

  @thermostat_json """
  {
    "@context": "dtmi:dtdl:context;3",
    "@type": "Interface",
    "@id": "dtmi:com:example:Thermostat;1",
    "extends": ["dtmi:com:example:BaseThing;1"],
    "contents": [
      {
        "@type": "Telemetry",
        "name": "temperature",
        "extends-check": true,
        "schema": "double"
      },
      {
        "@type": ["Telemetry"],
        "name": "lastHeartbeat",
        "schema": "dateTime"
      },
      {
        "@type": "Property",
        "name": "targetTemp",
        "schema": "integer",
        "writable": true
      },
      {
        "@type": "Relationship",
        "name": "hostedBy",
        "target": "dtmi:com:example:Device;1",
        "minMultiplicity": 0
      },
      {
        "@type": "Relationship",
        "name": "isSpareFor",
        "target": "sh:NodeShape"
      }
    ]
  }
  """

  @device_json """
  {
    "@context": "dtmi:dtdl:context;3",
    "@type": "Interface",
    "@id": "dtmi:com:example:Device;1",
    "contents": [
      {
        "@type": "Telemetry",
        "name": "status",
        "schema": "string"
      }
    ]
  }
  """

  @building_json """
  {
    "@context": "dtmi:dtdl:context;3",
    "@id": "dtmi:com:example:Building;1",
    "@type": "Interface",
    "contents": [
      {
        "@type": "Component",
        "name": "thermostat",
        "schema": "dtmi:com:example:Thermostat;1"
      }
    ]
  }
  """

  @base_thing_json """
  {
    "@context": "dtmi:dtdl:context;3",
    "@type": "Interface",
    "@id": "dtmi:com:example:BaseThing;1",
    "contents": [
      {
        "@type": "Telemetry",
        "name": "deviceId",
        "schema": "string"
      }
    ]
  }
  """

  test "3-node model converts, compiles, and enforces via guards" do
    doc = """
    [
      #{String.trim(@device_json)},
      #{String.trim(@base_thing_json)},
      #{String.trim(@thermostat_json)},
      #{String.trim(@building_json)}
    ]
    """

    assert {:ok, res} = DTDL.convert(doc)

    assert res.interfaces == [
             "dtmi:com:example:Device;1",
             "dtmi:com:example:BaseThing;1",
             "dtmi:com:example:Thermostat;1",
             "dtmi:com:example:Building;1"
           ]

    assert res.shapes == 4

    # dtmi IRIs are <>-quoted, never bare prefixed local names (the @prefix
    # declaration line is the only legal bare `dtmi:`).
    assert res.ttl =~ "<dtmi:com:example:Thermostat;1> a sh:NodeShape"
    refute Regex.match?(~r/(?<!<)dtmi:com/, res.ttl)

    # RDF triple projection: interface types, extends chain, relationship
    # target, component schema reference.
    assert {"dtmi:com:example:Thermostat;1", "rdf:type", "dtdl:Interface"} in res.triples
    assert {"dtmi:com:example:Thermostat;1", "dtdl:extends", "dtmi:com:example:BaseThing;1"} in res.triples
    assert {"dtmi:com:example:Thermostat;1/contents3", "dtdl:target", "dtmi:com:example:Device;1"} in res.triples
    assert {"dtmi:com:example:Building;1/contents0", "dtdl:schema", "dtmi:com:example:Thermostat;1"} in res.triples

    assert {:ok, guards} = LawCompiler.compile_all(res.ttl)
    assert MapSet.new(Map.keys(guards)) == MapSet.new(["Device;1", "BaseThing;1", "Thermostat;1", "Building;1"])

    th = Map.fetch!(guards, "Thermostat;1")
    dev = Map.fetch!(guards, "Device;1")
    bld = Map.fetch!(guards, "Building;1")

    # -- conforming twin telemetry admits ------------------------------------

    good = %{
      "temperature" => 21.5,
      "lastHeartbeat" => "2026-10-22T09:30:00Z",
      "targetTemp" => 20,
      "deviceId" => "th-1"
    }

    assert th.(good) == :ok
    assert dev.(%{"status" => "online"}) == :ok
    assert bld.(%{"thermostat" => good}) == :ok

    # -- telemetry datatype refuses (sh:datatype, the 6th class) ---------------

    {:violation, rule, _diag} = th.(Map.put(good, "temperature", "21.5"))
    assert rule =~ "Thermostat;1/datatype/temperature"

    {:violation, rule, _diag} = th.(Map.put(good, "lastHeartbeat", "not-a-date"))
    assert rule =~ "Thermostat;1/datatype/lastHeartbeat"

    # inherited deviceId (extends flattening) datatype-enforces on the child
    {:violation, rule, _diag} = th.(Map.put(good, "deviceId", 7))
    assert rule =~ "Thermostat;1/datatype/deviceId"
    assert dev.(%{"status" => 1}) |> elem(0) == :violation

    # -- writable property required (writable + sh:minCount 1) ------------------

    {:violation, rule, _diag} = th.(Map.delete(good, "targetTemp"))
    assert rule =~ "Thermostat;1/minCount/targetTemp"

    # -- relationship target shape (sh:qualifiedValueShape) ---------------------

    assert th.(Map.put(good, "hostedBy", %{"target" => "dtmi:com:example:Device;1"})) == :ok

    {:violation, rule, _diag} = th.(Map.put(good, "hostedBy", %{"target" => 42}))
    assert rule =~ "Thermostat;1/qualifiedValueShape/hostedBy"

    {:violation, rule, _diag} = th.(Map.put(good, "hostedBy", "dtmi:com:example:Device;1"))
    assert rule =~ "Thermostat;1/qualifiedValueShape/hostedBy"

    # -- component instance shape (qualified value shape over the schema) -------

    {:violation, _rule, _diag} = bld.(%{"thermostat" => Map.put(good, "temperature", "hot")})

    {:violation, _rule, _diag} = bld.(%{"thermostat" => "not-a-map"})
  end

  test "malformed DTDL refuses typed" do
    # invalid JSON grammar
    assert {:error, {:invalid_json, _}} = DTDL.convert("{not json")

    # interface without @type
    assert {:error, {:missing_at_type, "dtmi:com:example:NoType;1"}} =
             DTDL.convert(~s({"@id": "dtmi:com:example:NoType;1"}))

    # content node without @type
    assert {:error, {:missing_at_type, _}} =
             DTDL.convert(~s({"@type": "Interface", "@id": "dtmi:com:example:I;1",
               "contents": [{"name": "x", "schema": "string"}]}))

    # content without name
    assert {:error, {:missing_name, _}} =
             DTDL.convert(~s({"@type": "Interface", "@id": "dtmi:com:example:I;1",
               "contents": [{"@type": "Telemetry", "schema": "string"}]}))

    # non-primitive schema
    assert {:error, {:unsupported_schema, _}} =
             DTDL.convert(~s({"@type": "Interface", "@id": "dtmi:com:example:I;1",
               "contents": [{"@type": "Telemetry", "name": "t", "schema": "Object"}]}))

    # extends reference outside the document
    assert {:error, {:unknown_extends, "dtmi:com:example:Ghost;1"}} =
             DTDL.convert(~s({"@type": "Interface", "@id": "dtmi:com:example:I;1",
               "extends": ["dtmi:com:example:Ghost;1"]}))
  end
end
