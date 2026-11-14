# GS2 Pub/Sub Census

Standing: UNVERIFIED

Substrate found: `Smalt.DataPlane.QueueStorage` (popreceipt + visibility timeout = ack id +
ack deadline; FIFO by seq; `now_ms` clock seam), `Smalt.PubSubGrpc.Engine` (gRPC face, AoQ log;
no ordering/DLQ/snapshots/seek), `Smalt.Messaging.*` (Azure-dialect engines).

Chosen backing: QueueStorage, one queue per subscription (account = project). Delivery state
(ack ids, ordering in-flight keys, attempts, snapshots) in a serialized GenServer.

Gaps vs REST v1 not covered: push subscriptions, exactly-once delivery, schemas, IAM,
message retention duration, filter expressions, `retainAckedMessages` toggling (always retained).
