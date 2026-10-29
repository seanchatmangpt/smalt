defmodule Smalt.POWL2.LawCompilerCourt do
  @moduledoc """
  GL-2 court: shape→guard compiler classes on real TTL + real context maps.
  Chicago discipline: no mocks — real TTL text, real predicate execution.
  """

  use ExUnit.Case, async: false

  alias Smalt.POWL2.LawCompiler

  @order_ttl """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <https://example.com/law#> .
  @prefix powl: <https://ggen.io/ontology/powl2#> .

  ex:OrderShape a sh:NodeShape ;
      sh:targetClass ex:Order ;
      sh:property [
          sh:path ex:orderTotal ;
          sh:maxInclusive 10000 ;
          sh:message "order total over 10000 requires a compliance signature" ;
      ] .
  """

  @consent_ttl """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <https://example.com/law#> .

  ex:ConsentShape a sh:NodeShape ;
      sh:targetClass ex:Processing ;
      sh:property [
          sh:path ex:gdprConsent ;
          sh:minCount 1 ;
          sh:message "GDPR consent tag required before processing" ;
      ] .
  """

  @approval_ttl """
  @prefix sh: <http://www.w3.org/super#> .
  @prefix ex: <https://example.com/law#> .
  @prefix powl: <https://ggen.io/ontology/powl2#> .

  ex:ApprovalShape a sh:NodeShape ;
      sh:property [
          sh:path ex:actor ;
          powl:notEquals ex:reportSubject ;
          sh:message "actor cannot approve own report" ;
      ] .
  """

  # -- maxInclusive ---------------------------------------------------------

  describe "maxInclusive class" do
    test "compiles to a guard_fun and passes at/below the ceiling" do
      assert {:ok, guard} = LawCompiler.compile_shape("ex:OrderShape", @order_ttl)
      assert is_function(guard, 1)
      assert guard.(%{"orderTotal" => 9_500}) == :ok
      assert guard.(%{"orderTotal" => 10_000}) == :ok
    end

    test "order over 10k is a violation with rule_id + diagnostic" do
      {:ok, guard} = LawCompiler.compile_shape("OrderShape", @order_ttl)
      assert {:violation, "OrderShape/maxInclusive/orderTotal", diag} =
               guard.(%{"orderTotal" => 10_001})

      # the shape carries sh:message, so it overrides the default diagnostic
      assert diag == "order total over 10000 requires a compliance signature"
    end

    test "missing value and non-numeric value are fail-closed violations, never crashes" do
      {:ok, guard} = LawCompiler.compile_shape("OrderShape", @order_ttl)
      assert {:violation, "OrderShape/maxInclusive/orderTotal", _} = guard.(%{})
      assert {:violation, "OrderShape/maxInclusive/orderTotal", _} = guard.(%{"orderTotal" => nil})
      assert {:violation, "OrderShape/maxInclusive/orderTotal", _} = guard.(%{"orderTotal" => "huge"})
      # atom-keyed context tolerated
      assert guard.(%{orderTotal: 42}) == :ok
    end

    test "custom message overrides the default; default diagnostic carries both numbers" do
      {:ok, guard} = LawCompiler.compile_shape("OrderShape", @order_ttl)
      assert {:violation, _, "order total over 10000 requires a compliance signature"} =
               guard.(%{"orderTotal" => 20_000})

      bare_ttl = """
      ex:OrderShape a sh:NodeShape ;
          sh:property [ sh:path ex:orderTotal ; sh:maxInclusive 10000 ] .
      """

      {:ok, guard} = LawCompiler.compile_shape("OrderShape", bare_ttl)
      assert {:violation, _, diag} = guard.(%{"orderTotal" => 10_001})
      assert diag =~ "10000"
      assert diag =~ "10001"
    end
  end

  # -- minCount -------------------------------------------------------------

  describe "minCount class (GDPR consent)" do
    test "presence passes, absence/nil is a violation" do
      {:ok, guard} = LawCompiler.compile_shape("ex:ConsentShape", @consent_ttl)
      assert guard.(%{"gdprConsent" => "granted"}) == :ok
      assert {:violation, "ConsentShape/minCount/gdprConsent", diag} = guard.(%{})
      assert diag =~ "GDPR consent"
      assert {:violation, _, _} = guard.(%{"gdprConsent" => nil})
    end
  end

  # -- exclusion ------------------------------------------------------------

  describe "exclusion class (subject != object)" do
    test "actor != reportSubject passes; actor == reportSubject violates" do
      {:ok, guard} = LawCompiler.compile_shape("ApprovalShape", @approval_ttl)
      assert guard.(%{"actor" => "u1", "reportSubject" => "u2"}) == :ok
      assert {:violation, "ApprovalShape/notEquals/actor", diag} =
               guard.(%{"actor" => "u1", "reportSubject" => "u1"})

      assert diag =~ "actor cannot approve own report"
    end

    test "either side absent is not an exclusion violation (presence is minCount's job)" do
      {:ok, guard} = LawCompiler.compile_shape("ApprovalShape", @approval_ttl)
      assert guard.(%{"actor" => "u1"}) == :ok
      assert guard.(%{}) == :ok
    end
  end

  # -- compile-time errors --------------------------------------------------

  describe "typed compile errors" do
    test "malformed TTL is a typed parse_error, never a raise" do
      # non-shape statements are skipped by design (ShapeFile discipline);
      # malformed = a structural error inside a real shape statement
      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape("X", "ex:Foo a sh:NodeShape ; sh:bogusKey 1 .")

      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape("X", "ex:Foo a sh:NodeShape ; sh:property [ ex:bare ] .")

      assert {:error, {:parse_error, _}} = LawCompiler.compile_shape("X", "ex:Foo a sh:NodeShape ; sh:property [ sh:path ")
      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape("X", ~s(ex:Foo a sh:NodeShape ; sh:description "unterminated))

      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape(
                 "X",
                 "ex:Foo a sh:NodeShape ; sh:property [ sh:path ex:p ; sh:bogus 1 ] ."
               )
    end

    test "unknown shape is typed, lists the requested iri" do
      assert {:error, {:unknown_shape, "ex:Missing"}} =
               LawCompiler.compile_shape("ex:Missing", @order_ttl)
    end
  end

  # -- multi-shape + compile_all ---------------------------------------------

  describe "compile_all" do
    test "compiles every shape; each guard enforces its own class" do
      ttl = @order_ttl <> "\n" <> @consent_ttl

      assert {:ok, guards} = LawCompiler.compile_all(ttl)
      assert MapSet.new(Map.keys(guards)) == MapSet.new(["OrderShape", "ConsentShape"])

      assert guards["OrderShape"].(%{"orderTotal" => 1}) == :ok
      assert {:violation, _, _} = guards["OrderShape"].(%{})

      assert guards["ConsentShape"].(%{"gdprConsent" => true}) == :ok
      assert {:violation, _, _} = guards["ConsentShape"].(%{})
    end
  end
end
