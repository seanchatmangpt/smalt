defmodule Smalt.ServengineSim.OcelV2LogValidatorTest do
  use ExUnit.Case, async: true

  alias Smalt.GCP.Logging
  alias Smalt.ServengineSim.OcelV2LogValidator
  alias Smalt.Telemetry.OcelNdjson

  defp valid_doc(overrides \\ %{}) do
    base = %{
      "ocel:version" => "2.0",
      "ocel:eventTypes" => [
        %{
          "name" => "workOrder.updated",
          "attributes" => [%{"name" => "stage", "type" => "string"}]
        }
      ],
      "ocel:objectTypes" => [
        %{"name" => "WorkOrder"},
        %{"name" => "Provider"}
      ],
      "ocel:events" => [
        %{
          "id" => "550e8400-e29b-41d4-a716-446655440000",
          "type" => "workOrder.updated",
          "time" => "2026-11-19T16:00:00Z",
          "attributes" => %{
            "stage" => "dispatched",
            "correlation_id" => "corr-20261119-001",
            "order_ref" => "4111111111111112"
          },
          "relationships" => [
            %{"objectId" => "wo-1001", "qualifier" => "workorder"},
            %{"objectId" => "sp-2002", "qualifier" => "provider"}
          ]
        }
      ],
      "ocel:objects" => [
        %{
          "id" => "wo-1001",
          "type" => "WorkOrder",
          "attributes" => %{"priority" => "emergency"},
          "relationships" => [%{"objectId" => "sp-2002", "qualifier" => "assigned_to"}]
        },
        %{
          "id" => "sp-2002",
          "type" => "Provider",
          "attributes" => %{}
        }
      ]
    }

    Map.merge(base, overrides)
  end

  defp valid_stdout_line(extra \\ %{}) do
    valid_doc()
    |> Map.merge(%{
      "severity" => "INFO",
      "logging.googleapis.com/trace" => "projects/ai-cmd-ctr/traces/abc123"
    })
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp codes(violations), do: Enum.map(violations, & &1.code)

  describe "valid OCEL v2 stdout jsonPayload & wasm4pm/ex4pm compatibility" do
    test "accepts direct stdout JSON line, lowers into Ex4pm.EventLog, and supports Ex4pm.OCEL.flatten/2" do
      line = valid_stdout_line()

      assert {:ok, report} = OcelV2LogValidator.validate_line(line)
      assert report.valid == true
      assert report.pii_clean == true
      assert report.event_count == 1
      assert report.object_count == 2
      assert %Ex4pm.EventLog{} = report.ex4pm_log
      assert length(report.ex4pm_log.object_relationships) == 1

      assert {:ok, %{"wo-1001" => [ev]}} = Ex4pm.OCEL.flatten(report.ex4pm_log, "WorkOrder")
      assert ev.activity == "workOrder.updated"
      assert OcelV2LogValidator.valid?(line)
    end

    test "accepts nested jsonPayload.ocel and Cloud Logging entry envelope" do
      nested_entry = %{
        "logName" => "projects/ai-cmd-ctr/logs/run.googleapis.com%2Fstdout",
        "severity" => "NOTICE",
        "timestamp" => "2026-11-19T16:00:01Z",
        "jsonPayload" => %{
          "correlation_id" => "corr-nested-1",
          "ocel" => valid_doc()
        }
      }

      assert {:ok, report} = OcelV2LogValidator.validate_line(Jason.encode!(nested_entry))
      assert report.event_count == 1
      assert report.object_count == 2
      assert %Ex4pm.EventLog{} = report.ex4pm_log
    end

    test "accepts canonical OCEL 2.0 list-of-pair attributes with timestamps" do
      doc =
        valid_doc(%{
          "ocel:events" => [
            %{
              "id" => "ev-list-1",
              "type" => "workOrder.updated",
              "time" => "2026-11-19T16:00:00Z",
              "attributes" => [%{"name" => "stage", "value" => "completed"}],
              "relationships" => [%{"objectId" => "wo-1001", "qualifier" => "workorder"}]
            }
          ],
          "ocel:objects" => [
            %{
              "id" => "wo-1001",
              "type" => "WorkOrder",
              "attributes" => [
                %{"name" => "status", "value" => "open", "time" => "2026-11-19T15:00:00Z"},
                %{"name" => "status", "value" => "closed", "time" => "2026-11-19T16:00:00Z"}
              ]
            },
            %{"id" => "sp-2002", "type" => "Provider", "attributes" => []}
          ]
        })

      assert {:ok, report} = OcelV2LogValidator.validate_line(doc)

      assert Ex4pm.ObjectRef.attribute_at(
               report.ex4pm_log.objects["wo-1001"],
               "status",
               "2026-11-19T15:30:00Z"
             ) == "open"

      assert Ex4pm.ObjectRef.attribute_at(report.ex4pm_log.objects["wo-1001"], "status") ==
               "closed"
    end

    test "validates lines emitted by Smalt.Telemetry.OcelNdjson.append/3" do
      dir = Path.join(System.tmp_dir!(), "ocel-v2-val-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      event = %{
        "id" => "01934567-89ab-7cde-8123-456789abcdef",
        "type" => "cosmos.doc.crud",
        "time" => "2026-11-19T16:00:00Z",
        "attributes" => %{"method" => "PUT", "status" => 200},
        "relationships" => [%{"objectId" => "doc-42", "qualifier" => "resource"}]
      }

      objects = [%{"id" => "doc-42", "type" => "resource", "attributes" => %{}}]

      assert {:ok, path} =
               OcelNdjson.append(event, objects, dir: dir, agent: "urn:smalt:agent:sim-1")

      assert {:ok, [report]} = path |> File.read!() |> OcelV2LogValidator.validate_lines()
      assert report.event_count == 1
      assert report.object_count == 2
    end

    test "round-trips through Smalt.GCP.Logging write_entries/list_entries" do
      project = "sim-#{System.unique_integer([:positive])}"

      entry = %{
        "severity" => "INFO",
        "jsonPayload" => valid_doc()
      }

      assert {:ok, %{}} =
               Logging.write_entries(%{
                 "logName" => "projects/#{project}/logs/stdout",
                 "resource" => %{"type" => "cloud_run_revision"},
                 "entries" => [entry]
               })

      assert {:ok, %{"entries" => [stored]}} =
               Logging.list_entries(%{"resourceNames" => ["projects/#{project}"]})

      assert {:ok, report} = OcelV2LogValidator.validate_line(stored)
      assert report.valid == true
    end
  end

  describe "GCP Cloud Logging stdout framing refusals" do
    test "refuses empty, malformed, non-object, multiline, and oversized lines" do
      assert {:error, [%{code: :empty_line}]} = OcelV2LogValidator.validate_line("   \n")
      assert {:error, [%{code: :invalid_json}]} = OcelV2LogValidator.validate_line("{not json")
      assert {:error, [%{code: :non_object_json}]} = OcelV2LogValidator.validate_line("[1, 2, 3]")

      multiline = "{\n\"a\": 1}"

      assert {:error, [%{code: :multiline_log_line}]} =
               OcelV2LogValidator.validate_line(multiline)

      assert {:error, [%{code: :payload_too_large}]} =
               OcelV2LogValidator.validate_line(valid_stdout_line(), max_bytes: 64)
    end

    test "refuses textPayload-only Cloud Logging entries and invalid severities" do
      text_only = %{"severity" => "INFO", "textPayload" => "unstructured log line"}
      assert {:error, errs} = OcelV2LogValidator.validate_line(text_only)
      assert :text_payload_only in codes(errs)

      bad_sev = valid_doc(%{"severity" => "LOUD"})
      assert {:error, errs} = OcelV2LogValidator.validate_line(bad_sev)
      assert :invalid_severity in codes(errs)
    end

    test "enforces ocel:version 2.0 when present or when require_version: true" do
      bad_ver = valid_doc(%{"ocel:version" => "1.0"})
      assert {:error, errs} = OcelV2LogValidator.validate_line(bad_ver)
      assert :unsupported_ocel_version in codes(errs)

      no_ver = Map.delete(valid_doc(), "ocel:version")
      assert {:ok, _} = OcelV2LogValidator.validate_line(no_ver)
      assert {:error, errs} = OcelV2LogValidator.validate_line(no_ver, require_version: true)
      assert :missing_ocel_version in codes(errs)
    end
  end

  describe "OCEL v2 & wasm4pm OCEDO/OCPQ structural invariants" do
    test "refuses missing or non-array top-level OCEL keys" do
      missing = Map.delete(valid_doc(), "ocel:objectTypes")
      assert {:error, errs} = OcelV2LogValidator.validate_line(missing)
      assert :missing_ocel_key in codes(errs)

      bad_type = valid_doc(%{"ocel:events" => %{}})
      assert {:error, errs} = OcelV2LogValidator.validate_line(bad_type)
      assert :invalid_ocel_key_type in codes(errs)
    end

    test "refuses empty ocel:events by default unless allow_empty_events: true" do
      empty = valid_doc(%{"ocel:events" => []})
      assert {:error, errs} = OcelV2LogValidator.validate_line(empty)
      assert :empty_events in codes(errs)
      assert {:ok, _} = OcelV2LogValidator.validate_line(empty, allow_empty_events: true)
    end

    test "refuses undeclared event/object types and duplicate ids" do
      undeclared =
        valid_doc(%{
          "ocel:eventTypes" => [],
          "ocel:objectTypes" => [%{"name" => "WorkOrder"}]
        })

      assert {:error, errs} = OcelV2LogValidator.validate_line(undeclared)
      assert :undeclared_event_type in codes(errs)
      assert :undeclared_object_type in codes(errs)

      dup_ids =
        valid_doc(%{
          "ocel:events" => valid_doc()["ocel:events"] ++ valid_doc()["ocel:events"],
          "ocel:objects" => valid_doc()["ocel:objects"] ++ valid_doc()["ocel:objects"]
        })

      assert {:error, errs2} = OcelV2LogValidator.validate_line(dup_ids)
      assert :duplicate_event_id in codes(errs2)
      assert :duplicate_object_id in codes(errs2)
    end

    test "refuses empty E2O, dangling E2O, dangling O2O, and bad timestamps" do
      empty_e2o =
        valid_doc(%{
          "ocel:events" => [
            %{
              "id" => "ev-empty-rel",
              "type" => "workOrder.updated",
              "time" => "not-a-timestamp",
              "attributes" => %{},
              "relationships" => []
            }
          ]
        })

      assert {:error, errs} = OcelV2LogValidator.validate_line(empty_e2o)
      assert :e2o_empty in codes(errs)
      assert :invalid_timestamp in codes(errs)

      assert {:ok, _} =
               OcelV2LogValidator.validate_line(
                 put_in(empty_e2o, ["ocel:events", Access.at(0), "time"], "2026-11-19T16:00:00Z"),
                 require_e2o: false
               )

      dangling =
        valid_doc(%{
          "ocel:events" => [
            %{
              "id" => "ev-dang",
              "type" => "workOrder.updated",
              "time" => "2026-11-19T16:00:00Z",
              "attributes" => %{},
              "relationships" => [%{"objectId" => "missing-obj", "qualifier" => "workorder"}]
            }
          ],
          "ocel:objects" => [
            %{
              "id" => "wo-1001",
              "type" => "WorkOrder",
              "relationships" => [%{"objectId" => "missing-o2o", "qualifier" => "assigned_to"}]
            },
            %{"id" => "sp-2002", "type" => "Provider"}
          ]
        })

      assert {:error, errs2} = OcelV2LogValidator.validate_line(dangling)
      assert :dangling_e2o in codes(errs2)
      assert :dangling_o2o in codes(errs2)
    end

    test "enforces optional wasm4pm object-type cardinality windows" do
      assert {:error, errs} =
               OcelV2LogValidator.validate_line(valid_doc(),
                 cardinality: %{"WorkOrder" => %{min_count: 2}}
               )

      assert :cardinality_min in codes(errs)

      assert {:error, errs2} =
               OcelV2LogValidator.validate_line(valid_doc(),
                 cardinality: %{"Provider" => %{max_count: 0}}
               )

      assert :cardinality_max in codes(errs2)
    end
  end

  describe "PII & secret redaction enforcement" do
    test "refuses unredacted PII/credential keys in map and list-of-pair attributes" do
      unredacted_map =
        put_in(valid_doc(), ["ocel:events", Access.at(0), "attributes"], %{
          "email" => "tech@example.com",
          "phoneNumber" => "555-234-5678",
          "apiKey" => "sk_live_secret_value"
        })

      assert {:error, errs} = OcelV2LogValidator.validate_line(unredacted_map)
      assert Enum.count(errs, &(&1.code == :unredacted_pii_key)) == 3

      unredacted_pairs =
        put_in(valid_doc(), ["ocel:events", Access.at(0), "attributes"], [
          %{"name" => "ssn", "value" => "123-45-6789"},
          %{"name" => "fullName", "value" => "Jane Doe"}
        ])

      assert {:error, errs2} = OcelV2LogValidator.validate_line(unredacted_pairs)
      assert Enum.count(errs2, &(&1.code == :unredacted_pii_key)) == 2
    end

    test "allows properly redacted PII/credential sentinel and masked values" do
      redacted =
        put_in(valid_doc(), ["ocel:events", Access.at(0), "attributes"], %{
          "email" => "t***@example.com",
          "phoneNumber" => "+1******5678",
          "ssn" => "***-**-6789",
          "password" => "[REDACTED]",
          "token" => "eyJ<redacted>",
          "dob" => "[redacted]",
          "notes" => nil
        })

      assert {:ok, report} = OcelV2LogValidator.validate_line(redacted)
      assert report.pii_clean == true
    end

    test "catches raw PII, JWT, Bearer, private key, and Luhn-valid PAN leaked into generic keys" do
      fake_jwt =
        "eyJ" <>
          String.duplicate("a", 16) <>
          "." <> String.duplicate("b", 16) <> "." <> String.duplicate("c", 16)

      fake_pem = "-----BEGIN " <> "RSA PRIVATE KEY-----"

      leaked =
        put_in(valid_doc(), ["ocel:events", Access.at(0), "attributes"], %{
          "note_email" => "contact alice@example.com ASAP",
          "note_ssn" => "taxpayer 123-45-6789 verified",
          "note_phone" => "callback +1 (415) 555-1234",
          "note_jwt" => "header=#{fake_jwt}",
          "note_bearer" => "Authorization: Bearer super_secret_token_value_1234",
          "note_key" => fake_pem,
          "note_pan" => "card 4111-1111-1111-1111"
        })

      assert {:error, errs} = OcelV2LogValidator.validate_line(leaked)
      err_codes = MapSet.new(codes(errs))

      assert :pii_email_leaked in err_codes
      assert :pii_ssn_leaked in err_codes
      assert :pii_phone_leaked in err_codes
      assert :pii_jwt_leaked in err_codes
      assert :pii_bearer_leaked in err_codes
      assert :pii_private_key_leaked in err_codes
      assert :pii_pan_leaked in err_codes
    end
  end

  describe "validate_lines/2 multi-line stdout stream" do
    test "validates multi-line stdout output skipping blank lines and tags line numbers on failure" do
      blob = valid_stdout_line() <> "\n\n" <> valid_stdout_line() <> "\n"
      assert {:ok, reports} = OcelV2LogValidator.validate_lines(blob)
      assert Enum.map(reports, & &1.line) == [1, 3]

      bad_blob = valid_stdout_line() <> "\n" <> "{broken"

      assert {:error, [%{line: 2, code: :invalid_json}]} =
               OcelV2LogValidator.validate_lines(bad_blob)
    end
  end
end
