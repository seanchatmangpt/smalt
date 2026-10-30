package messaging

import (
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
)

var castagnoliTable = crc32.MakeTable(crc32.Castagnoli)

// KafkaRequestHeader represents the standard Kafka request envelope.
type KafkaRequestHeader struct {
	Size          int32
	APIKey        int16
	APIVersion    int16
	CorrelationID int32
	ClientID      string
}

// ComputeCRC32C computes the hardware-accelerated Castagnoli CRC32C over data.
func ComputeCRC32C(data []byte) uint32 {
	return crc32.Checksum(data, castagnoliTable)
}

// ParseKafkaRequestHeader decodes a Kafka request header.
func ParseKafkaRequestHeader(r io.Reader) (*KafkaRequestHeader, error) {
	var prefix [12]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return nil, err
	}

	size := int32(binary.BigEndian.Uint32(prefix[0:4]))
	apiKey := int16(binary.BigEndian.Uint16(prefix[4:6]))
	apiVersion := int16(binary.BigEndian.Uint16(prefix[6:8]))
	corrID := int32(binary.BigEndian.Uint32(prefix[8:12]))

	// Read client ID length
	var clientIDLenBytes [2]byte
	if _, err := io.ReadFull(r, clientIDLenBytes[:]); err != nil {
		return nil, err
	}
	clientIDLen := int16(binary.BigEndian.Uint16(clientIDLenBytes[:]))

	var clientID string
	if clientIDLen > 0 {
		cidBuf := make([]byte, clientIDLen)
		if _, err := io.ReadFull(r, cidBuf); err != nil {
			return nil, err
		}
		clientID = string(cidBuf)
	}

	return &KafkaRequestHeader{
		Size:          size,
		APIKey:        apiKey,
		APIVersion:    apiVersion,
		CorrelationID: corrID,
		ClientID:      clientID,
	}, nil
}

// RecordBatchHeader represents a Kafka RecordBatch Magic 2 header (v2).
type RecordBatchHeader struct {
	BaseOffset           int64
	BatchLength          int32
	PartitionLeaderEpoch int32
	Magic                int8
	CRC                  uint32
	Attributes           int16
	LastOffsetDelta      int32
	FirstTimestamp       int64
	MaxTimestamp         int64
	ProducerID           int64
	ProducerEpoch        int16
	BaseSequence         int32
	RecordCount          int32
}

// ParseRecordBatchHeader parses and verifies a Magic 2 RecordBatch header.
func ParseRecordBatchHeader(data []byte) (*RecordBatchHeader, error) {
	if len(data) < 61 {
		return nil, errors.New("record batch header buffer too small (min 61 bytes)")
	}

	baseOffset := int64(binary.BigEndian.Uint64(data[0:8]))
	batchLength := int32(binary.BigEndian.Uint32(data[8:12]))
	leaderEpoch := int32(binary.BigEndian.Uint32(data[12:16]))
	magic := int8(data[16])
	if magic != 2 {
		return nil, fmt.Errorf("unsupported Kafka record batch magic: %d (expected 2)", magic)
	}

	crc := binary.BigEndian.Uint32(data[17:21])
	attributes := int16(binary.BigEndian.Uint16(data[21:23]))
	lastOffsetDelta := int32(binary.BigEndian.Uint32(data[23:27]))
	firstTimestamp := int64(binary.BigEndian.Uint64(data[27:35]))
	maxTimestamp := int64(binary.BigEndian.Uint64(data[35:43]))
	producerID := int64(binary.BigEndian.Uint64(data[43:51]))
	producerEpoch := int16(binary.BigEndian.Uint16(data[51:53]))
	baseSequence := int32(binary.BigEndian.Uint32(data[53:57]))
	recordCount := int32(binary.BigEndian.Uint32(data[57:61]))

	// Verify CRC32C over bytes following CRC field (offset 21 onwards)
	computedCRC := ComputeCRC32C(data[21 : 12+batchLength])
	if computedCRC != crc {
		return nil, fmt.Errorf("record batch CRC32C mismatch: wire=%d, computed=%d", crc, computedCRC)
	}

	return &RecordBatchHeader{
		BaseOffset:           baseOffset,
		BatchLength:          batchLength,
		PartitionLeaderEpoch: leaderEpoch,
		Magic:                magic,
		CRC:                  crc,
		Attributes:           attributes,
		LastOffsetDelta:      lastOffsetDelta,
		FirstTimestamp:       firstTimestamp,
		MaxTimestamp:         maxTimestamp,
		ProducerID:           producerID,
		ProducerEpoch:        producerEpoch,
		BaseSequence:         baseSequence,
		RecordCount:          recordCount,
	}, nil
}
