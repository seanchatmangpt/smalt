package storage_test

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"testing"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/storage"
)

func TestWALWriter_AppendAndFrameVerification(t *testing.T) {
	t.Parallel()

	var disk bytes.Buffer
	wal := storage.NewWALWriter(&disk)

	payload1 := []byte(`{"event":"ResourceCreated","id":"sub-1"}`)
	payload2 := []byte(`{"event":"ResourceUpdated","id":"sub-1"}`)

	rec1, err := wal.Append(payload1)
	require.NoError(t, err)
	require.Equal(t, uint64(1), rec1.Sequence)
	require.Equal(t, crc32.ChecksumIEEE(payload1), rec1.CRC32)

	rec2, err := wal.Append(payload2)
	require.NoError(t, err)
	require.Equal(t, uint64(2), rec2.Sequence)

	require.Equal(t, uint64(2), wal.RecordCount())

	// Validate wire framing
	wireBytes := disk.Bytes()
	require.Greater(t, len(wireBytes), 12)

	magic := binary.BigEndian.Uint32(wireBytes[0:4])
	require.Equal(t, uint32(storage.WALMagic), magic)

	length := binary.BigEndian.Uint32(wireBytes[4:8])
	require.Equal(t, uint32(len(payload1)), length)

	checksum := binary.BigEndian.Uint32(wireBytes[8:12])
	require.Equal(t, rec1.CRC32, checksum)
}
