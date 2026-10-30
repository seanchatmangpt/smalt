package messaging_test

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/messaging"
)

func TestAMQP_FrameHeaderAndMultiplexing(t *testing.T) {
	t.Parallel()

	// 1. Encode & Parse Frame Header
	origHeader := &messaging.AMQPFrameHeader{
		Size:    256,
		DOFF:    2,
		Type:    0,
		Channel: 5,
	}

	var buf [8]byte
	err := messaging.EncodeAMQPFrameHeader(origHeader, buf[:])
	require.NoError(t, err)

	parsed, err := messaging.ParseAMQPFrameHeader(bytes.NewReader(buf[:]))
	require.NoError(t, err)
	require.Equal(t, origHeader.Size, parsed.Size)
	require.Equal(t, origHeader.DOFF, parsed.DOFF)
	require.Equal(t, origHeader.Type, parsed.Type)
	require.Equal(t, origHeader.Channel, parsed.Channel)

	// 2. Multiplexing
	mux := messaging.NewChannelMultiplexer()
	channel5Received := false

	mux.RegisterChannel(5, func(h *messaging.AMQPFrameHeader, payload []byte) error {
		channel5Received = true
		require.Equal(t, uint16(5), h.Channel)
		return nil
	})

	err = mux.Dispatch(parsed, []byte("amqp-payload-bytes"))
	require.NoError(t, err)
	require.True(t, channel5Received)

	// Unregistered channel fails
	unregHeader := &messaging.AMQPFrameHeader{Channel: 99}
	err = mux.Dispatch(unregHeader, nil)
	require.Error(t, err)
}

func TestKafka_CRC32CAndRecordBatchHeader(t *testing.T) {
	t.Parallel()

	// Compute CRC32C over payload
	payload := []byte("kafka-message-payload-12345")
	crc := messaging.ComputeCRC32C(payload)
	require.NotZero(t, crc)

	// Build valid RecordBatch Header buffer
	batchLength := int32(49 + len(payload))
	buf := make([]byte, 12+batchLength)

	binary.BigEndian.PutUint64(buf[0:8], 100)                     // BaseOffset
	binary.BigEndian.PutUint32(buf[8:12], uint32(batchLength))    // BatchLength
	binary.BigEndian.PutUint32(buf[12:16], 0)                     // PartitionLeaderEpoch
	buf[16] = 2                                                   // Magic 2
	binary.BigEndian.PutUint16(buf[21:23], 0)                     // Attributes
	binary.BigEndian.PutUint32(buf[23:27], 0)                     // LastOffsetDelta
	binary.BigEndian.PutUint64(buf[27:35], 1600000000000)         // FirstTimestamp
	binary.BigEndian.PutUint64(buf[35:43], 1600000000000)         // MaxTimestamp
	binary.BigEndian.PutUint64(buf[43:51], 10)                    // ProducerID
	binary.BigEndian.PutUint16(buf[51:53], 1)                     // ProducerEpoch
	binary.BigEndian.PutUint32(buf[53:57], 0)                     // BaseSequence
	binary.BigEndian.PutUint32(buf[57:61], 1)                     // RecordCount
	copy(buf[61:], payload)

	// CRC is calculated over buf[21:]
	computedCRC := messaging.ComputeCRC32C(buf[21 : 12+batchLength])
	binary.BigEndian.PutUint32(buf[17:21], computedCRC)

	// Parse and verify
	header, err := messaging.ParseRecordBatchHeader(buf)
	require.NoError(t, err)
	require.Equal(t, int64(100), header.BaseOffset)
	require.Equal(t, computedCRC, header.CRC)
	require.Equal(t, int8(2), header.Magic)
}
