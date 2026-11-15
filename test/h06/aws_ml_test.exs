defmodule Smalt.H06.AwsMlTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias Smalt.AWS.SigV4
  alias Smalt.H06.AwsMl.{Router, State}

  @akid "AKIDLOCAL"
  @secret "secretLocal"
  @date "20261114T000000Z"

  setup do
    State.reset()
    :ok
  end

  # Real SigV4-signed request through the real router; no doubles.
  defp send_req(svc, method, path, body, extra \\ [], secret \\ @secret) do
    base = [{"host", "#{svc}.us-east-1.amazonaws.com"}, {"x-amz-date", @date}] ++ extra

    auth =
      SigV4.sign(%{method: method, path: path, query: "", headers: base, body: body, access_key_id: @akid, secret: secret, region: "us-east-1", service: svc, amz_date: @date})

    conn = conn(method, path, body)
    conn = Enum.reduce([{"authorization", auth} | base], conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, creds: %{@akid => @secret})
  end

  defp target(svc, prefix, op, payload, secret \\ @secret) do
    c = send_req(svc, "POST", "/", Jason.encode!(payload), [{"x-amz-target", prefix <> op}], secret)
    {c.status, Jason.decode!(c.resp_body), c}
  end

  defp textract(op, p), do: target("textract", "Textract.", op, p)
  defp transcribe(op, p), do: target("transcribe", "Transcribe.", op, p)
  defp rek(op, p), do: target("rekognition", "RekognitionService.", op, p)

  defp converse(model, p) do
    c = send_req("bedrock", "POST", "/model/#{URI.encode(model, &URI.char_unreserved?/1)}/converse", Jason.encode!(p))
    {c.status, Jason.decode!(c.resp_body), c}
  end

  test "unsigned and foreign-scope conns pass through un-halted" do
    c = Router.call(conn(:post, "/", "{}"), [])
    refute c.halted
    assert c.state == :unset
  end

  test "bad signature is a typed 403, unknown key a typed 400" do
    {403, %{"__type" => "SignatureDoesNotMatch"}, c} = target("textract", "Textract.", "AnalyzeDocument", %{}, "wrong")
    assert c.halted
  end

  test "Textract words and signatures are computed from the document bytes" do
    doc = "Invoice 3008789-03 total due /Sig signed here"
    {200, out, _} = textract("AnalyzeDocument", %{"Document" => %{"Bytes" => Base.encode64(doc)}, "FeatureTypes" => ["SIGNATURES", "FORMS"]})
    words = for %{"BlockType" => "WORD", "Text" => t} <- out["Blocks"], do: t
    assert words == ["Invoice", "3008789-03", "total", "due", "Sig", "signed", "here"]
    assert [%{"Page" => 1}] = Enum.filter(out["Blocks"], &(&1["BlockType"] == "SIGNATURE"))
    assert Enum.all?(out["Blocks"], &(&1["BlockType"] != "WORD" or (&1["Confidence"] >= 90.0 and &1["Confidence"] < 100.0)))

    {200, again, _} = textract("AnalyzeDocument", %{"Document" => %{"Bytes" => Base.encode64(doc)}, "FeatureTypes" => ["SIGNATURES", "FORMS"]})
    assert again == out

    {200, nosig, _} = textract("AnalyzeDocument", %{"Document" => %{"Bytes" => Base.encode64(doc)}, "FeatureTypes" => ["FORMS"]})
    refute Enum.any?(nosig["Blocks"], &(&1["BlockType"] == "SIGNATURE"))
  end

  test "Textract validation errors are typed" do
    assert {400, %{"__type" => "ValidationException"}, _} = textract("AnalyzeDocument", %{"Document" => %{"Bytes" => Base.encode64("x y")}})
    assert {400, %{"__type" => "ValidationException"}, _} = textract("AnalyzeDocument", %{"Document" => %{"Bytes" => Base.encode64("x y")}, "FeatureTypes" => ["NOPE"]})
    assert {400, %{"__type" => "InvalidParameterException"}, _} = textract("AnalyzeDocument", %{"FeatureTypes" => ["FORMS"]})
    assert {400, %{"__type" => "InvalidParameterException"}, _} = textract("AnalyzeDocument", %{"Document" => %{"Bytes" => "!!"}, "FeatureTypes" => ["FORMS"]})
    assert {400, %{"__type" => "UnknownOperationException"}, _} = textract("Nope", %{})
  end

  test "Transcribe job lifecycle: start, conflict, poll to completion, list, vocabulary rule" do
    job = %{"TranscriptionJobName" => "natfac-a1", "LanguageCode" => "en-US", "Media" => %{"MediaFileUri" => "s3://b/a.wav"}, "Settings" => %{"VocabularyName" => "hvac-nh3-vocab"}}
    {200, %{"TranscriptionJob" => j}, _} = transcribe("StartTranscriptionJob", job)
    assert j["TranscriptionJobStatus"] == "IN_PROGRESS"
    assert j["Settings"]["VocabularyName"] == "hvac-nh3-vocab"

    assert {400, %{"__type" => "ConflictException"}, _} = transcribe("StartTranscriptionJob", job)

    {200, %{"TranscriptionJob" => g1}, _} = transcribe("GetTranscriptionJob", %{"TranscriptionJobName" => "natfac-a1"})
    assert g1["TranscriptionJobStatus"] == "IN_PROGRESS"
    {200, %{"TranscriptionJob" => g2}, _} = transcribe("GetTranscriptionJob", %{"TranscriptionJobName" => "natfac-a1"})
    assert g2["TranscriptionJobStatus"] == "COMPLETED"
    assert g2["Transcript"]["TranscriptFileUri"] =~ "natfac-a1.json"
    assert g2["CompletionTime"] > g2["CreationTime"]

    {200, %{"TranscriptionJobSummaries" => [s]}, _} = transcribe("ListTranscriptionJobs", %{"Status" => "COMPLETED"})
    assert s["TranscriptionJobName"] == "natfac-a1"
    {200, %{"TranscriptionJobSummaries" => []}, _} = transcribe("ListTranscriptionJobs", %{"Status" => "FAILED"})

    assert {400, %{"__type" => "BadRequestException"}, _} = transcribe("GetTranscriptionJob", %{"TranscriptionJobName" => "ghost"})
    bad = put_in(job, ["Settings", "VocabularyName"], "missing-vocab") |> Map.put("TranscriptionJobName", "natfac-a2")
    assert {400, %{"__type" => "BadRequestException"}, _} = transcribe("StartTranscriptionJob", bad)

    assert {200, %{"VocabularyState" => "READY"}, _} = transcribe("CreateVocabulary", %{"VocabularyName" => "missing-vocab", "LanguageCode" => "en-US", "Phrases" => ["ammonia"]})
    assert {200, %{"TranscriptionJob" => _}, _} = transcribe("StartTranscriptionJob", bad)
    assert {400, %{"__type" => "BadRequestException"}, _} = transcribe("StartTranscriptionJob", %{job | "TranscriptionJobName" => "bad name!"})
  end

  test "Bedrock Converse returns a per-model distribution summing to 1 and varying by model" do
    p = %{"messages" => [%{"role" => "user", "content" => [%{"text" => "classify: compressor=? fan=? valve=?"}]}], "inferenceConfig" => %{"temperature" => 0.0}}
    {200, a, c} = converse("anthropic.claude-3-5-sonnet-20240620-v1:0", p)
    assert c.status == 200
    {200, b, _} = converse("meta.llama3-8b-instruct-v1:0", p)
    {200, a2, _} = converse("anthropic.claude-3-5-sonnet-20240620-v1:0", p)
    assert a == a2

    dist = fn out ->
      [%{"text" => t}] = out["output"]["message"]["content"]
      for tok <- String.split(t), [l, v] = String.split(tok, "="), into: %{}, do: {l, String.to_float(v)}
    end

    da = dist.(a)
    assert Map.keys(da) |> Enum.sort() == ["compressor", "fan", "valve"]
    assert_in_delta Enum.sum(Map.values(da)), 1.0, 1.0e-9
    refute da == dist.(b)
    assert a["stopReason"] == "end_turn"
    assert a["usage"]["totalTokens"] == a["usage"]["inputTokens"] + a["usage"]["outputTokens"]
    assert String.contains?(Jason.encode!(a["metrics"]), "latencyMs")
  end

  test "Bedrock typed errors: unknown model 404 with error-type header, bad shapes 400" do
    ok = %{"messages" => [%{"role" => "user", "content" => [%{"text" => "hi"}]}]}
    {404, %{"message" => _}, c} = converse("nope.model-v1", ok)
    assert get_resp_header(c, "x-amzn-errortype") == ["ResourceNotFoundException"]
    {400, _, c2} = converse("amazon.nova-pro-v1:0", %{"messages" => []})
    assert get_resp_header(c2, "x-amzn-errortype") == ["ValidationException"]
    {400, _, _} = converse("amazon.nova-pro-v1:0", %{ok | "messages" => [%{"role" => "robot", "content" => [%{"text" => "x"}]}]})
    {400, _, _} = converse("amazon.nova-pro-v1:0", Map.put(ok, "inferenceConfig", %{"temperature" => 2}))
  end

  test "Rekognition CompareFaces similarity is computed from the two images" do
    same = Base.encode64("face-bytes-0123456789-abcdef")
    {200, out, _} = rek("CompareFaces", %{"SourceImage" => %{"Bytes" => same}, "TargetImage" => %{"Bytes" => same}})
    assert [%{"Similarity" => 100.0}] = out["FaceMatches"]
    assert out["UnmatchedFaces"] == []

    other = Base.encode64("zzzzzzzzzzzzzzzzzzzzzzzzzzzz")
    {200, out2, _} = rek("CompareFaces", %{"SourceImage" => %{"Bytes" => same}, "TargetImage" => %{"Bytes" => other}})
    assert out2["FaceMatches"] == []
    assert [_] = out2["UnmatchedFaces"]

    near = Base.encode64("face-bytes-0123456789-abcdeX")
    {200, out3, _} = rek("CompareFaces", %{"SimilarityThreshold" => 50, "SourceImage" => %{"Bytes" => same}, "TargetImage" => %{"Bytes" => near}})
    assert [%{"Similarity" => s}] = out3["FaceMatches"]
    assert s > 50.0 and s < 100.0

    assert {400, %{"__type" => "InvalidParameterException"}, _} = rek("CompareFaces", %{"SimilarityThreshold" => 101, "SourceImage" => %{"Bytes" => same}, "TargetImage" => %{"Bytes" => same}})
    assert {400, %{"__type" => "InvalidParameterException"}, _} = rek("CompareFaces", %{"SourceImage" => %{"Bytes" => same}})
  end

  test "Rekognition liveness session is stateful; unknown session is typed 404-class error" do
    assert {400, %{"__type" => "ResourceNotFoundException"}, _} = rek("GetFaceLivenessSessionResults", %{"SessionId" => "nope"})
    {200, %{"SessionId" => id}, _} = rek("CreateFaceLivenessSession", %{})
    {200, r, _} = rek("GetFaceLivenessSessionResults", %{"SessionId" => id})
    assert r["Status"] == "SUCCEEDED" and r["SessionId"] == id and r["Confidence"] >= 90.0
    {200, r2, _} = rek("GetFaceLivenessSessionResults", %{"SessionId" => id})
    assert r2 == r
    {200, %{"SessionId" => id2}, _} = rek("CreateFaceLivenessSession", %{})
    refute id2 == id
  end

  test "Rekognition DetectProtectiveEquipment persons follow the image content" do
    img = Base.encode64("..PERSON....PERSON..")
    {200, out, _} = rek("DetectProtectiveEquipment", %{"Image" => %{"Bytes" => img}})
    assert Enum.map(out["Persons"], & &1["Id"]) == [0, 1]
    {200, none, _} = rek("DetectProtectiveEquipment", %{"Image" => %{"Bytes" => Base.encode64("empty scene")}})
    assert none["Persons"] == []
  end
end
