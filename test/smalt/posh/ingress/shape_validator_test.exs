defmodule Smalt.Posh.Ingress.ShapeValidatorTest do
  @moduledoc """
  Lane 44 Chicago courts for the G32 Option C landing: real collaborators
  (compiled pack shapes, parsed A-box, generated pipeline module), final-state
  assertions, no doubles.
  """

  use ExUnit.Case, async: false

  alias Smalt.Posh.Ingress.{Admission, ShapeValidator}

  @ns "https://smalt.dev/posh/ns#"

  defp conformant_frame do
    %{
      "admittedBy" => @ns <> "turnstileResourceGroup",
      "shape" => @ns <> "ResourceGroupShape",
      "membraneOp" => "arm.resource_group"
    }
  end

  defp iri, do: @ns <> "ResourceGroupShape"

  # -- compiled shapes / A-box -------------------------------------------------------

  test "compiles the pack's ingress shapes from the real TTL on disk" do
    keys = Map.keys(ShapeValidator.shapes()) |> Enum.sort()
    assert keys == ["ArmRequestShape", "IngressRouteShape", "NoBypassShape"]

    ingress = ShapeValidator.shapes()["IngressRouteShape"]
    assert ingress.closed
    assert ingress.target_class == "IngressRoute"
    assert "type" in ingress.ignored
  end

  test "NoBypassShape carries the posh:emits ban (sh:maxCount 0)" do
    no_bypass = ShapeValidator.shapes()["NoBypassShape"]
    refute no_bypass.closed
    assert Enum.any?(no_bypass.props, fn p -> p.key == "emits" and p.max == 0 end)
  end

  test "compiles Turnstile/Sink individuals from the real A-box" do
    ind = ShapeValidator.individuals()
    assert MapSet.size(ind["Turnstile"]) >= 3
    assert MapSet.member?(ind["Sink"], "sinkStarboard9443")
  end

  # -- conformant admits / violations refuse ------------------------------------------

  test "shape-conformant payload admits" do
    assert ShapeValidator.validate(iri(), conformant_frame()) == :ok
  end

  test "extra-key payload refused (sh:closed)" do
    frame = Map.put(conformant_frame(), "extraKey", 1)
    assert {:refused, {:shape_violation, %{violations: vs}}} = ShapeValidator.validate("x", frame)
    assert Enum.any?(vs, fn v -> v.constraint == "closed" and v.path == "$.extraKey" end)
  end

  test "emits-on-route refused (Law 2 ban, sh:maxCount 0)" do
    frame = Map.put(conformant_frame(), "emits", @ns <> "receiptBLAH")
    assert {:refused, {:shape_violation, %{violations: vs}}} = ShapeValidator.validate("x", frame)
    assert Enum.any?(vs, fn v -> v.constraint == "maxCount" and v.path == "$.emits" end)
  end

  test "missing required key refused (sh:minCount 1)" do
    frame = Map.delete(conformant_frame(), "membraneOp")
    assert {:refused, {_, %{violations: vs}}} = ShapeValidator.validate("x", frame)
    assert Enum.any?(vs, fn v -> v.constraint == "minCount" end)
  end

  test "admittedBy naming a non-Turnstile refused (sh:class)" do
    frame = Map.put(conformant_frame(), "admittedBy", @ns <> "routeResourceGroup")
    assert {:refused, {_, %{violations: vs}}} = ShapeValidator.validate("x", frame)
    assert Enum.any?(vs, fn v -> v.constraint == "class" end)
  end

  test "hostile frames return typed refusals, never crash" do
    assert {:refused, {:shape_violation, %{violations: vs}}} = ShapeValidator.validate("x", :not_a_map)
    assert Enum.any?(vs, fn v -> v.constraint == "closed" end)

    atom_key_frame = Map.put(conformant_frame(), :atom_key, 1)
    assert {:refused, {:shape_violation, %{violations: vs}}} = ShapeValidator.validate("x", atom_key_frame)
    assert Enum.any?(vs, fn v -> v.constraint == "closed" end)
  end

  # -- fail-closed ggen-sync guard -------------------------------------------------------

  test "unsupported constraint keyword raises at parse time (fail-closed)" do
    ttl = """
    posh:EvilShape a sh:NodeShape ;
      sh:targetClass posh:IngressRoute ;
      sh:property [ sh:path posh:p ; sh:pattern "^arm" ] .
    """

    assert_raise Smalt.Posh.Ingress.ShapeValidator.UnsupportedConstraint, ~r/sh:pattern/, fn ->
      ShapeValidator.TTL.parse!(ttl, "test")
    end
  end

  # -- Admission seam (closed + ban + class via compiled policy) ----------------------------

  test "Admission policy compiled from the pack shapes enforces closed + ban + class" do
    policy = Admission.compile(ShapeValidator.admission_policy())

    assert {:admitted, _} =
             Admission.validate(policy, "arm.resource_group", conformant_frame())

    extra = Map.put(conformant_frame(), "extraKey", 1)

    assert {:refused, {:shape_violation, %{violations: vs}}} =
             Admission.validate(policy, "arm.resource_group", extra)

    assert Enum.any?(vs, fn v -> v.issue == "unknown_key" end)

    ban = Map.put(conformant_frame(), "emits", @ns <> "receiptBLAH")

    assert {:refused, {:shape_violation, %{violations: vs}}} =
             Admission.validate(policy, "arm.resource_group", ban)

    assert Enum.any?(vs, fn v -> v.issue == "banned_key" end)

    class = Map.put(conformant_frame(), "admittedBy", @ns <> "routeResourceGroup")

    assert {:refused, {:shape_violation, %{violations: vs}}} =
             Admission.validate(policy, "arm.resource_group", class)

    assert Enum.any?(vs, fn v -> v.issue == "class_violation" end)
  end

  # -- admission crash budget still bounded ------------------------------------------------

  test "admission crash budget stays bounded under a crashing shape spec" do
    # the budget path requires the real TaskSupervisor; if the app tree is
    # absent (bare ExUnit boot), start it — the crash containment is the
    # subject under test, not supervisor absence
    if is_nil(Process.whereis(Smalt.Posh.Ingress.TaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: Smalt.Posh.Ingress.TaskSupervisor})
    end

    policy = Admission.compile(%{"arm.request" => %{required: [], types: %{}, shape: :not_a_map}})

    assert {:refused, {:admission_crash, :restart_budget_exhausted}} =
             Admission.validate_task(policy, "arm.request", %{})
  end

  # -- generated pipeline module calls the real validator -------------------------------------

  test "generated pipeline module validate/2 is no longer an unconditional :ok stub" do
    mod = Smalt.Posh.Pipeline.Arm_resource_group
    assert mod.validate(conformant_frame(), mod.shape_iri()) == :ok

    bad = Map.put(conformant_frame(), "extraKey", 1)
    assert {:refused, _} = mod.validate(bad, mod.shape_iri())
  end

  # -- bench: intake hot path (CTQ < 10 us; record honest numbers) -------------------------------

  @tag :bench
  test "intake validate hot path p50/p99 vs the 10us CTQ" do
    frame = conformant_frame()
    mod = Smalt.Posh.Pipeline.Arm_resource_group
    shape_iri = mod.shape_iri()

    for _ <- 1..1000, do: mod.validate(frame, shape_iri)

    samples =
      for _ <- 1..20_000 do
        {us, :ok} = :timer.tc(fn -> mod.validate(frame, shape_iri) end)
        us
      end

    sorted = Enum.sort(samples)
    p50 = Enum.at(sorted, div(length(sorted), 2))
    p99 = Enum.at(sorted, trunc(length(sorted) * 0.99))
    IO.puts("[L44-BENCH] validate/2 hot path p50=#{p50}us p99=#{p99}us (CTQ <10us, n=20000)")

    policy = Admission.compile(ShapeValidator.admission_policy())

    task_samples =
      for _ <- 1..500 do
        {us, _} = :timer.tc(fn -> Admission.validate_task(policy, "arm.resource_group", frame) end)
        us
      end

    t = Enum.sort(task_samples)
    IO.puts("[L44-BENCH] Admission.validate_task p50=#{Enum.at(t, 250)}us p99=#{Enum.at(t, 495)}us (n=500)")

    assert p99 < 1000, "validate/2 p99 #{p99}us exploded beyond sanity (<1ms)"
  end
end
