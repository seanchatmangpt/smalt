defmodule Smalt.H06.Vocab do
  @moduledoc """
  H06 named-constant vocabulary for the AWS ML plane (Textract, Transcribe,
  Bedrock Runtime, Rekognition): SigV4 scope services, target prefixes, route
  shapes, limits, error codes. Emitters read from here, never inline strings.
  """

  @services ["textract", "transcribe", "bedrock", "rekognition"]
  @target_prefix %{
    "textract" => "Textract.",
    "transcribe" => "Transcribe.",
    "rekognition" => "RekognitionService."
  }
  @json11 "application/x-amz-json-1.1"
  @json "application/json"
  @textract_features ["TABLES", "FORMS", "QUERIES", "SIGNATURES", "LAYOUT"]
  @model_prefixes ["anthropic.", "meta.", "amazon.", "us.", "eu.", "mistral.", "cohere.", "ai21."]
  @roles ["user", "assistant"]
  @default_labels ["yes", "no"]
  @max_words 1_000
  @logical_clock_base 1_700_000_000
  @transcript_bucket_host "https://s3.us-east-1.amazonaws.com/smalt-transcribe"
  @job_name_re ~r/^[0-9a-zA-Z._-]{1,200}$/
  @default_vocabularies ["hvac-nh3-vocab"]

  def services, do: @services
  def target_prefix(service), do: Map.fetch!(@target_prefix, service)
  def json11, do: @json11
  def json, do: @json
  def textract_features, do: @textract_features
  def model_prefixes, do: @model_prefixes
  def roles, do: @roles
  def default_labels, do: @default_labels
  def max_words, do: @max_words
  def logical_clock_base, do: @logical_clock_base
  def transcript_bucket_host, do: @transcript_bucket_host
  def job_name_re, do: @job_name_re

  @doc "Vocabularies pre-provisioned at plane start (config `:smalt, :h06_vocabularies`)."
  def default_vocabularies, do: Application.get_env(:smalt, :h06_vocabularies, @default_vocabularies)
end
