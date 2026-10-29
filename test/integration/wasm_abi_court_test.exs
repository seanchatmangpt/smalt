# GWS-7 court: smalt host bridge vs the REAL graphlaw wasm ABI
# (graphlaw src/abi.rs ABI_VERSION=1, tests/wasm_abi.rs call_json protocol).
#
# Encoding round-trip, both directions, over real bytes — no mocks:
#   pack (smalt focus node -> ABI call_json request map)
#   encode (request map -> exact call_json bytes)
#   decode (ABI response bytes -> ok verdict / typed abi_refusal)
#   unpack (decoded verdict -> smalt guard envelope)
#
# Context: solo (integration tier).

defmodule Smalt.Integration.WasmAbiCourtTest do
  use ExUnit.Case, async: false

  Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

  alias Smalt.Wasm.{Bridge, Worker}

  @sample_nt "<https://e/s> <https://e/p> <https://e/o> .\n"

  @shapes ~S(@prefix sh: <http://www.w3.org/ns/shacl#> . @prefix ex: <https://e/> .
  ex:S a sh:NodeShape ; sh:targetClass ex:T ; sh:property [ sh:path ex:p ; sh:datatype xsd:integer ] .)

  # -- pack leg: smalt focus node -> REAL ABI call_json request shape --------

  test "pack_focus_node with shapes emits the real shacl op with a data spec" do
    req = Bridge.pack_focus_node(%{"text" => @sample_nt, "shapes" => @shapes})

    assert req == %{
             "op" => "shacl",
             "data" => %{"text" => @sample_nt, "dialect" => "ntriples"},
             "shapes" => @shapes
           }
  end

  test "pack_focus_node without shapes emits the real parse op" do
    req = Bridge.pack_focus_node(%{"text" => @sample_nt, "base" => "https://e/"})

    assert req == %{
             "op" => "parse",
             "text" => @sample_nt,
             "dialect" => "ntriples",
             "base" => "https://e/"
           }
  end

  test "pack refuses a focus node with no RDF text (typed raise, no fake frame)" do
    assert_raise(ArgumentError, fn -> Bridge.pack_focus_node(%{"q" => "x"}) end)
  end

  test "encode produces the exact call_json bytes and re-decodes to the same shape" do
    req = Bridge.pack_focus_node(%{"text" => @sample_nt, "shapes" => @shapes})
    bytes = Bridge.encode_request(req)

    # The bytes are exactly what gl_alloc would buffer for gl_call: one JSON
    # object whose string form round-trips byte-shape-identical.
    assert Jason.decode!(bytes) == req
    assert bytes |> Jason.decode!() |> Bridge.encode_request() == bytes
  end

  # -- decode leg: real ABI response frames, both outcomes -------------------

  test "decode admits a real ok response (parse)" do
    raw =
      Jason.encode!(%{
        "ok" => true,
        "dialect" => "NTriples",
        "valid" => true
      })

    assert {:ok, verdict} = Bridge.decode_response(raw)
    assert verdict["valid"] == true
    assert Bridge.unpack_verdict({:ok, verdict}) |> elem(0) == :ok
  end

  test "decode maps a real ok:false refusal to the typed abi_refusal" do
    raw =
      Jason.encode!(%{
        "ok" => false,
        "error" => %{
          "kind" => "NotSemanticContent",
          "engine" => nil,
          "dialect" => nil,
          "message" => "content sniff: not semantic content",
          "details" => %{"code" => "NotSemanticContent"}
        }
      })

    assert {:error, {:abi_refusal, refusal}} = Bridge.decode_response(raw)
    assert refusal.kind == "NotSemanticContent"
    assert refusal.engine == nil
    assert refusal.dialect == nil
    assert refusal.message =~ "not semantic content"
    assert refusal.details["code"] == "NotSemanticContent"
  end

  test "decode handles the ResourceLimit refusal shape with details" do
    raw =
      Jason.encode!(%{
        "ok" => false,
        "error" => %{
          "kind" => "ResourceLimit",
          "engine" => nil,
          "dialect" => nil,
          "message" => "resource limit `request_bytes` exceeded: 20000000 > 16777216",
          "details" => %{"code" => "ResourceLimit", "limit" => "request_bytes",
                         "observed" => 20_000_000, "max" => 16_777_216}
        }
      })

    assert {:error, {:abi_refusal, refusal}} = Bridge.decode_response(raw)
    assert refusal.kind == "ResourceLimit"
    assert refusal.details["max"] == 16_777_216
  end

  test "decode refuses a frame with no ok field (typed malformed, never a guess)" do
    assert {:error, {:malformed_frame, _}} = Bridge.decode_response(Jason.encode!(%{"x" => 1}))
    assert {:error, {:malformed_frame, _}} = Bridge.decode_response(<<0, 1, 2, 3>>)
  end

  test "unpack maps a real shacl non-conform verdict to a typed guard refusal" do
    verdict = %{"conforms" => false, "results" => [%{"focus" => "https://e/s"}]}

    assert {:error, {:abi_refusal, refusal}} = Bridge.unpack_verdict({:ok, verdict})
    assert refusal.kind == "EngineRejected"
    assert refusal.details["code"] == "NotAdmitted"
    assert refusal.details["results"] == verdict["results"]
  end

  # -- worker surface ---------------------------------------------------------

  test "worker reports ABI version 1 (graphlaw src/abi.rs)" do
    assert Worker.abi_version() == 1
  end

  # -- stub-mode end to end: the REAL ABI request bytes cross the port --------

  test "eval over a map focus node rides the stub with real ABI request bytes" do
    start_supervised!({Smalt.Wasm.Pool, size: 1, timeout_ms: 5_000})

    # The focus node is packed to the real shacl request; the stub answers
    # its documented refusal envelope (it is a transport stub, not a
    # graphlaw host). The eval path must admit that envelope unchanged.
    assert {:ok, result} = Bridge.eval(%{"text" => @sample_nt, "shapes" => @shapes})
    assert result["code"] == "refusal_envelope"
    assert result["http"] == 429
    assert result["detail"]["predicate_frames_count"] == 0
  end

  test "eval keeps the legacy raw-binary transport path green" do
    start_supervised!({Smalt.Wasm.Pool, size: 1, timeout_ms: 5_000})
    assert {:ok, result} = Bridge.eval(:crypto.strong_rand_bytes(64))
    assert result["http"] == 429
  end

  # BK-110 / SPOF-A A-7 kill-test: the supervised pool respawns a killed
  # worker (crash-only self-healing) and survives its own kill under a
  # supervisor — the production start site is Smalt.Plane.ControlSupervisor
  # when `config :smalt, :sync_guard == :wasm`.
  test "supervised pool self-heals a killed worker and survives a pool kill" do
    start_supervised!({Smalt.Wasm.Pool, size: 1, timeout_ms: 5_000})

    assert {:ok, worker} = Smalt.Wasm.Pool.checkout()
    Process.exit(worker, :kill)

    {:ok, _} =
      SmaltTest.Internal.Poll.eventually(fn ->
        if Smalt.Wasm.Pool.idle() == 1, do: {:ok, :respawned}, else: {:error, :drained}
      end)

    assert {:ok, fresh} = Smalt.Wasm.Pool.checkout()
    assert fresh != worker

    # pool-level kill: the supervising process must hand back a fresh pool
    old_pool = Process.whereis(Smalt.Wasm.Pool)
    Process.exit(old_pool, :kill)

    {:ok, _} =
      SmaltTest.Internal.Poll.eventually(fn ->
        case Process.whereis(Smalt.Wasm.Pool) do
          ^old_pool -> {:error, :still_dead}
          pid when is_pid(pid) -> {:ok, pid}
          nil -> {:error, :restarting}
        end
      end)

    assert Smalt.Wasm.Pool.idle() == 1
  end
end
