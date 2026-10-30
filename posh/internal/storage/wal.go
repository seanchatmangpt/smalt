package storage

import (
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
	"sync"
	"sync/atomic"
)

const (
	WALMagic = 0x57414C31 // "WAL1"
)

// WALRecord represents a single framed journal record.
type WALRecord struct {
	Sequence uint64
	CRC32    uint32
	Payload  []byte
}

// WALWriter is a concurrent, append-only log engine with CRC32 verification.
type WALWriter struct {
	mu       sync.RWMutex
	seq      atomic.Uint64
	records  []WALRecord
	writer   io.Writer
	crcTable *crc32.Table
}

// NewWALWriter constructs a WAL writer.
func NewWALWriter(out io.Writer) *WALWriter {
	return &WALWriter{
		records:  make([]WALRecord, 0, 1024),
		writer:   out,
		crcTable: crc32.MakeTable(crc32.IEEE),
	}
}

// Append frames the payload with length + CRC32 and appends it atomically.
func (w *WALWriter) Append(payload []byte) (*WALRecord, error) {
	if len(payload) == 0 {
		return nil, errors.New("cannot append empty WAL payload")
	}

	checksum := crc32.Checksum(payload, w.crcTable)
	seq := w.seq.Add(1)

	rec := WALRecord{
		Sequence: seq,
		CRC32:    checksum,
		Payload:  append([]byte(nil), payload...), // clone
	}

	w.mu.Lock()
	w.records = append(w.records, rec)

	if w.writer != nil {
		// Frame: Magic(4) | Length(4) | Checksum(4) | Payload
		var header [12]byte
		binary.BigEndian.PutUint32(header[0:4], WALMagic)
		binary.BigEndian.PutUint32(header[4:8], uint32(len(payload)))
		binary.BigEndian.PutUint32(header[8:12], checksum)

		if _, err := w.writer.Write(header[:]); err != nil {
			w.mu.Unlock()
			return nil, err
		}
		if _, err := w.writer.Write(payload); err != nil {
			w.mu.Unlock()
			return nil, err
		}
	}
	w.mu.Unlock()

	return &rec, nil
}

// RecordCount returns total records appended.
func (w *WALWriter) RecordCount() uint64 {
	return w.seq.Load()
}

// ReadFromSequence returns all records from startSeq onwards.
func (w *WALWriter) ReadFromSequence(startSeq uint64) []WALRecord {
	w.mu.RLock()
	defer w.mu.RUnlock()

	var out []WALRecord
	for _, r := range w.records {
		if r.Sequence >= startSeq {
			out = append(out, r)
		}
	}
	return out
}
