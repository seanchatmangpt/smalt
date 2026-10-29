# BK-KFKV scratch boot: app self-boots under MIX_ENV=test; print kafka port.
# Touch /tmp/bkkfkv-seal-trigger to seal the kafka journal sink, then keep serving.
Application.put_env(:smalt, :kafka_log_dir, System.get_env("SMALT_KAFKA_LOG_DIR") || "tmp/bkkfkv-kafka-journal")
IO.puts("KPORT=#{Smalt.Messaging.Kafka.Listener.port()}")
IO.puts("READY")
trigger = "/tmp/bkkfkv-seal-trigger"
Enum.each(Stream.repeatedly(fn -> File.exists?(trigger) end), fn
  true ->
    r = Smalt.Storage.JournalSink.seal(Smalt.Messaging.Kafka.Sink)
    File.write!("/tmp/bkkfkv-seal-result", inspect(r))
    IO.puts("SEALED #{inspect(r)}")
    exit(:normal)
  false ->
    Process.sleep(200)
end)
