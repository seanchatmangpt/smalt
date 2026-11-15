defmodule Smalt.H06.AwsMl do
  @moduledoc """
  H06 AWS ML plane: Textract, Transcribe, Bedrock Runtime (Converse) and
  Rekognition operations, computed from request inputs. Deterministic: every
  derived number comes from `:erlang.phash2/2` or byte statistics of the input,
  and time is a logical clock owned by `Smalt.H06.AwsMl.State`.

  Return shape for every op: `{:ok, map}` | `{:error, http_status, type, message}`.
  """
  alias Smalt.H06.{AwsMl.State, Vocab}

  # ---------------------------------------------------------------- dispatch

  def dispatch("textract", "AnalyzeDocument", p), do: analyze_document(p, true)
  def dispatch("textract", "DetectDocumentText", p), do: analyze_document(p, false)
  def dispatch("transcribe", "StartTranscriptionJob", p), do: start_job(p)
  def dispatch("transcribe", "GetTranscriptionJob", p), do: get_job(p)
  def dispatch("transcribe", "ListTranscriptionJobs", p), do: list_jobs(p)
  def dispatch("transcribe", "CreateVocabulary", p), do: create_vocab(p)
  def dispatch("transcribe", "GetVocabulary", p), do: get_vocab(p)
  def dispatch("rekognition", "CreateFaceLivenessSession", p), do: create_liveness(p)
  def dispatch("rekognition", "GetFaceLivenessSessionResults", p), do: liveness_results(p)
  def dispatch("rekognition", "CompareFaces", p), do: compare_faces(p)
  def dispatch("rekognition", "DetectProtectiveEquipment", p), do: detect_ppe(p)

  def dispatch(svc, op, _p),
    do: {:error, 400, "UnknownOperationException", "Operation #{op} is not served for #{svc}"}

  def converse(model_id, p), do: bedrock_converse(model_id, p)

  # ---------------------------------------------------------------- Textract

  defp analyze_document(p, needs_features?) do
    with {:ok, bytes} <- doc_bytes(p["Document"], "Document"),
         {:ok, feats} <- features(p["FeatureTypes"], needs_features?) do
      words = scan_words(bytes)

      word_blocks =
        words
        |> Enum.with_index()
        |> Enum.map(fn {w, i} ->
          h = :erlang.phash2({w, i}, 1000)

          %{
            "BlockType" => "WORD",
            "Id" => block_id("w", i),
            "Text" => w,
            "TextType" => "PRINTED",
            "Confidence" => (9000 + h) / 100,
            "Page" => 1,
            "Geometry" => %{"BoundingBox" => bbox(i)}
          }
        end)

      sig_blocks =
        if "SIGNATURES" in feats do
          Regex.scan(~r/\/Sig|SIGNATURE/, bytes, return: :index)
          |> Enum.with_index()
          |> Enum.map(fn {[{off, _}], i} ->
            %{
              "BlockType" => "SIGNATURE",
              "Id" => block_id("s", i),
              "Confidence" => (9000 + :erlang.phash2({off, i}, 1000)) / 100,
              "Page" => 1,
              "Geometry" => %{"BoundingBox" => bbox(off)}
            }
          end)
        else
          []
        end

      page = %{
        "BlockType" => "PAGE",
        "Id" => block_id("p", 0),
        "Page" => 1,
        "Geometry" => %{"BoundingBox" => %{"Width" => 1.0, "Height" => 1.0, "Left" => 0.0, "Top" => 0.0}},
        "Relationships" => [%{"Type" => "CHILD", "Ids" => Enum.map(word_blocks ++ sig_blocks, & &1["Id"])}]
      }

      {:ok,
       %{
         "Blocks" => [page | word_blocks ++ sig_blocks],
         "DocumentMetadata" => %{"Pages" => 1},
         "AnalyzeDocumentModelVersion" => "1.0"
       }}
    end
  end

  defp features(_, false), do: {:ok, []}

  defp features(nil, true), do: {:error, 400, "ValidationException", "FeatureTypes is required"}

  defp features(f, true) when is_list(f) and f != [] do
    case Enum.reject(f, &(&1 in Vocab.textract_features())) do
      [] -> {:ok, f}
      bad -> {:error, 400, "ValidationException", "Invalid FeatureTypes: #{Enum.join(bad, ",")}"}
    end
  end

  defp features(_, true), do: {:error, 400, "ValidationException", "FeatureTypes must be a non-empty list"}

  defp scan_words(bytes) do
    ~r/[A-Za-z0-9][A-Za-z0-9\-\.\/]+/
    |> Regex.scan(bytes)
    |> List.flatten()
    |> Enum.take(Vocab.max_words())
  end

  defp bbox(i) do
    %{
      "Width" => 0.08,
      "Height" => 0.02,
      "Left" => rem(i, 10) / 10,
      "Top" => rem(div(i, 10), 50) / 50
    }
  end

  defp block_id(kind, i) do
    <<a::32, b::16, c::16, d::16, e::48, _::binary>> = :crypto.hash(:sha256, "#{kind}:#{i}")
    hex = fn v, w -> v |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(w, "0") end
    Enum.join([hex.(a, 8), hex.(b, 4), hex.(c, 4), hex.(d, 4), hex.(e, 12)], "-")
  end

  defp doc_bytes(nil, name), do: {:error, 400, "InvalidParameterException", "Request has invalid parameters: #{name} is required"}

  defp doc_bytes(%{"Bytes" => b}, name) when is_binary(b) do
    case Base.decode64(b) do
      {:ok, <<>>} -> {:error, 400, "InvalidParameterException", "#{name} Bytes is empty"}
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, 400, "InvalidParameterException", "#{name} Bytes is not valid base64"}
    end
  end

  defp doc_bytes(%{"S3Object" => _}, name),
    do: {:error, 400, "InvalidS3ObjectException", "#{name} S3Object resolution is not served by this plane"}

  defp doc_bytes(_, name), do: {:error, 400, "InvalidParameterException", "#{name} needs Bytes or S3Object"}

  # -------------------------------------------------------------- Transcribe

  defp start_job(p) do
    name = p["TranscriptionJobName"]
    uri = get_in(p, ["Media", "MediaFileUri"])
    settings = p["Settings"] || %{}
    vocab = settings["VocabularyName"]

    cond do
      not is_binary(name) or not Regex.match?(Vocab.job_name_re(), name) ->
        {:error, 400, "BadRequestException", "1 validation error detected: TranscriptionJobName must match #{inspect(Vocab.job_name_re().source)}"}

      not is_binary(uri) or uri == "" ->
        {:error, 400, "BadRequestException", "Media.MediaFileUri is required"}

      not is_binary(p["LanguageCode"]) and p["IdentifyLanguage"] != true ->
        {:error, 400, "BadRequestException", "LanguageCode or IdentifyLanguage is required"}

      true ->
        State.update(fn st ->
          cond do
            Map.has_key?(st.jobs, name) ->
              {{:error, 400, "ConflictException", "The requested job name already exists. Use a different job name."}, st}

            is_binary(vocab) and not Map.has_key?(st.vocabs, vocab) ->
              {{:error, 400, "BadRequestException", "The requested vocabulary couldn't be found. Check the vocabulary name and try your request again."}, st}

            true ->
              {t, st} = tick(st)

              job = %{
                "TranscriptionJobName" => name,
                "TranscriptionJobStatus" => "IN_PROGRESS",
                "Media" => %{"MediaFileUri" => uri},
                "Settings" => settings,
                "CreationTime" => t,
                "StartTime" => t,
                "polls" => 0
              }

              job = if is_binary(p["LanguageCode"]), do: Map.put(job, "LanguageCode", p["LanguageCode"]), else: job
              {{:ok, %{"TranscriptionJob" => public_job(job)}}, put_in(st.jobs[name], job)}
          end
        end)
    end
  end

  defp get_job(%{"TranscriptionJobName" => name}) when is_binary(name) do
    State.update(fn st ->
      case st.jobs[name] do
        nil ->
          {{:error, 400, "BadRequestException", "The requested job couldn't be found. Check the job name and try your request again."}, st}

        job ->
          {t, st} = tick(st)

          job =
            if job["TranscriptionJobStatus"] == "IN_PROGRESS" and job["polls"] >= 1 do
              job
              |> Map.put("TranscriptionJobStatus", "COMPLETED")
              |> Map.put("CompletionTime", t)
              |> Map.put("Transcript", %{"TranscriptFileUri" => "#{Vocab.transcript_bucket_host}/#{name}.json"})
            else
              job
            end

          job = Map.update!(job, "polls", &(&1 + 1))
          {{:ok, %{"TranscriptionJob" => public_job(job)}}, put_in(st.jobs[name], job)}
      end
    end)
  end

  defp get_job(_), do: {:error, 400, "BadRequestException", "TranscriptionJobName is required"}

  defp list_jobs(p) do
    State.update(fn st ->
      jobs =
        st.jobs
        |> Map.values()
        |> Enum.filter(fn j ->
          (is_nil(p["Status"]) or j["TranscriptionJobStatus"] == p["Status"]) and
            (is_nil(p["JobNameContains"]) or String.contains?(j["TranscriptionJobName"], p["JobNameContains"]))
        end)
        |> Enum.sort_by(& &1["TranscriptionJobName"])
        |> Enum.map(&Map.take(&1, ["TranscriptionJobName", "TranscriptionJobStatus", "CreationTime", "LanguageCode"]))

      {{:ok, drop_nil(%{"TranscriptionJobSummaries" => jobs, "Status" => p["Status"]})}, st}
    end)
  end

  defp create_vocab(p) do
    name = p["VocabularyName"]

    cond do
      not is_binary(name) or not Regex.match?(Vocab.job_name_re(), name) ->
        {:error, 400, "BadRequestException", "VocabularyName is invalid"}

      not is_binary(p["LanguageCode"]) ->
        {:error, 400, "BadRequestException", "LanguageCode is required"}

      not is_list(p["Phrases"]) and not is_binary(p["VocabularyFileUri"]) ->
        {:error, 400, "BadRequestException", "Phrases or VocabularyFileUri is required"}

      true ->
        State.update(fn st ->
          if Map.has_key?(st.vocabs, name) do
            {{:error, 400, "ConflictException", "The requested vocabulary name already exists. Use a different vocabulary name."}, st}
          else
            {t, st} = tick(st)
            v = %{"VocabularyName" => name, "LanguageCode" => p["LanguageCode"], "VocabularyState" => "READY", "LastModifiedTime" => t, "Phrases" => p["Phrases"] || []}
            {{:ok, Map.take(v, ["VocabularyName", "LanguageCode", "VocabularyState", "LastModifiedTime"])}, put_in(st.vocabs[name], v)}
          end
        end)
    end
  end

  defp get_vocab(%{"VocabularyName" => name}) when is_binary(name) do
    State.update(fn st ->
      case st.vocabs[name] do
        nil -> {{:error, 400, "BadRequestException", "The requested vocabulary couldn't be found. Check the vocabulary name and try your request again."}, st}
        v -> {{:ok, Map.delete(v, "Phrases")}, st}
      end
    end)
  end

  defp get_vocab(_), do: {:error, 400, "BadRequestException", "VocabularyName is required"}

  defp public_job(job), do: Map.delete(job, "polls")

  # ----------------------------------------------------------------- Bedrock

  defp bedrock_converse(model_id, p) do
    msgs = p["messages"]
    temp = get_in(p, ["inferenceConfig", "temperature"])

    cond do
      not Enum.any?(Vocab.model_prefixes(), &String.starts_with?(model_id, &1)) ->
        {:error, 404, "ResourceNotFoundException", "The provided model identifier is invalid."}

      not is_list(msgs) or msgs == [] ->
        {:error, 400, "ValidationException", "messages must contain at least 1 item"}

      Enum.any?(msgs, fn m -> not is_map(m) or m["role"] not in Vocab.roles() or not is_list(m["content"]) or m["content"] == [] end) ->
        {:error, 400, "ValidationException", "each message needs role (user|assistant) and non-empty content"}

      not is_nil(temp) and (not is_number(temp) or temp < 0 or temp > 1) ->
        {:error, 400, "ValidationException", "inferenceConfig.temperature must be between 0 and 1"}

      true ->
        prompt = prompt_text(msgs)
        text = distribution_text(model_id, prompt)
        in_tok = prompt |> String.split() |> length()
        out_tok = text |> String.split() |> length()

        {:ok,
         %{
           "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => text}]}},
           "stopReason" => "end_turn",
           "usage" => %{"inputTokens" => in_tok, "outputTokens" => out_tok, "totalTokens" => in_tok + out_tok},
           "metrics" => %{"latencyMs" => 50 + :erlang.phash2({model_id, prompt}, 50)}
         }}
    end
  end

  defp prompt_text(msgs) do
    msgs
    |> Enum.flat_map(fn m -> for %{"text" => t} <- m["content"], is_binary(t), do: t end)
    |> Enum.join("\n")
  end

  # "label=prob ..." in permille, summing to exactly 1.000.
  defp distribution_text(model_id, prompt) do
    labels =
      case Regex.scan(~r/([A-Za-z_][\w\-]*)=/, prompt) |> Enum.map(&List.last/1) |> Enum.uniq() do
        [] -> Vocab.default_labels()
        ls -> ls
      end

    weights = Enum.map(labels, fn l -> 1 + :erlang.phash2({model_id, l, prompt}, 1000) end)
    total = Enum.sum(weights)
    pm = Enum.map(weights, &div(&1 * 1000, total))
    [first | rest] = pm
    pm = [first + (1000 - Enum.sum(pm)) | rest]

    labels
    |> Enum.zip(pm)
    |> Enum.map_join(" ", fn {l, v} -> "#{l}=#{div(v, 1000)}.#{v |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}" end)
  end

  # ------------------------------------------------------------- Rekognition

  defp create_liveness(_p) do
    State.update(fn st ->
      {_t, st} = tick(st)
      id = block_id("liveness", st.seq)
      {{:ok, %{"SessionId" => id}}, put_in(st.sessions[id], %{created: st.seq})}
    end)
  end

  defp liveness_results(%{"SessionId" => id}) when is_binary(id) do
    State.update(fn st ->
      case st.sessions[id] do
        nil ->
          {{:error, 400, "ResourceNotFoundException", "Session #{id} not found"}, st}

        _ ->
          {{:ok, %{"SessionId" => id, "Status" => "SUCCEEDED", "Confidence" => (9000 + :erlang.phash2(id, 1000)) / 100, "AuditImages" => []}}, st}
      end
    end)
  end

  defp liveness_results(_), do: {:error, 400, "InvalidParameterException", "SessionId is required"}

  defp compare_faces(p) do
    thr = Map.get(p, "SimilarityThreshold", 80)

    with {:ok, src} <- doc_bytes(p["SourceImage"], "SourceImage"),
         {:ok, tgt} <- doc_bytes(p["TargetImage"], "TargetImage"),
         :ok <- threshold(thr) do
      sim = similarity(src, tgt)
      face = %{"BoundingBox" => bbox(byte_size(tgt)), "Confidence" => 99.9}

      matches =
        if sim >= thr, do: [%{"Similarity" => sim, "Face" => face}], else: []

      unmatched = if sim >= thr, do: [], else: [face]

      {:ok,
       %{
         "SourceImageFace" => %{"BoundingBox" => bbox(byte_size(src)), "Confidence" => 99.9},
         "FaceMatches" => matches,
         "UnmatchedFaces" => unmatched
       }}
    end
  end

  defp threshold(t) when is_number(t) and t >= 0 and t <= 100, do: :ok
  defp threshold(_), do: {:error, 400, "InvalidParameterException", "SimilarityThreshold must be between 0 and 100"}

  # 4-gram Jaccard percent in hundredths; identical bytes are exactly 100.0.
  defp similarity(a, a), do: 100.0

  defp similarity(a, b) do
    sa = grams(a)
    sb = grams(b)
    union = MapSet.size(MapSet.union(sa, sb))

    if union == 0,
      do: 0.0,
      else: div(MapSet.size(MapSet.intersection(sa, sb)) * 10_000, union) / 100
  end

  defp grams(bin) when byte_size(bin) < 4, do: MapSet.new()

  defp grams(bin) do
    for i <- 0..(byte_size(bin) - 4), into: MapSet.new(), do: binary_part(bin, i, 4)
  end

  defp detect_ppe(p) do
    with {:ok, img} <- doc_bytes(p["Image"], "Image") do
      persons =
        ~r/PERSON/
        |> Regex.scan(img, return: :index)
        |> Enum.with_index()
        |> Enum.map(fn {[{off, _}], i} -> %{"Id" => i, "BoundingBox" => bbox(off), "Confidence" => 99.0, "BodyParts" => []} end)

      {:ok, %{"ProtectiveEquipmentModelVersion" => "1.0", "Persons" => persons}}
    end
  end

  # ----------------------------------------------------------------- helpers

  defp tick(st) do
    seq = st.seq + 1
    {Vocab.logical_clock_base() + seq + 0.0, %{st | seq: seq}}
  end

  defp drop_nil(m), do: m |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
