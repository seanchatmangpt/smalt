# KD-H06 AWS ML plane divergences

Standing: PARTIAL

Provider: `lib/smalt/h06/`. Tests: `test/h06/aws_ml_test.exs`.

| KD | Surface | Divergence | Evidence | Close condition |
|---|---|---|---|---|
| KD-H06-1 | Textract | Words come from printable-byte scan, not OCR; SIGNATURE blocks from `/Sig` or `SIGNATURE` markers; S3Object input returns `InvalidS3ObjectException` | `aws_ml.ex` analyze_document | Wire S3Object to `Smalt.AWS.S3` store and a real OCR corpus |
| KD-H06-2 | Bedrock | Converse text is a deterministic `label=prob` distribution (permille, sums to 1), not a model completion; labels are the `name=` tokens in the prompt | `aws_ml.ex` distribution_text | Real model adapter behind the same route |
| KD-H06-3 | Rekognition | Similarity is 4-gram Jaccard over image bytes; PPE persons are `PERSON` markers; no face detection | `aws_ml.ex` similarity/detect_ppe | Vision model or labeled image corpus |
| KD-H06-4 | Rekognition liveness | Session must be created via CreateFaceLivenessSession first (real behavior); fnox `rekognition_liveness` passes caller-chosen ids and gets ResourceNotFoundException until it creates one | `aws_sensors.py:101` | fnox creates the session before polling |
| KD-H06-5 | Transcribe | Job completes on the second Get (logical clock, no audio decode); transcript URI is not backed by an object | `aws_ml.ex` get_job | Back transcript with S3 sim object |
| KD-H06-6 | Cosmos, Event Hubs/Service Bus AMQP, Key Vault, Blob SAS, SQS/SNS/DynamoDB/STS | No fnox consumer found for these (grep of pipeline, scripts, infra, docs, ma); smalt already serves them under existing lanes, not re-audited here | `required-apis/H06.json` | A fnox consumer appears |
| KD-H06-7 | Transcribe vocabulary | `hvac-nh3-vocab` is pre-provisioned (config `:smalt, :h06_vocabularies`) because fnox starts jobs with it without creating it | `vocab.ex` | fnox issues CreateVocabulary |
