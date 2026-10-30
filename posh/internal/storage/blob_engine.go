package storage

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

// DefaultBufferSize is 64KB per chunk for high-throughput zero-copy streaming.
const DefaultBufferSize = 64 * 1024

var bufferPool = sync.Pool{
	New: func() any {
		b := make([]byte, DefaultBufferSize)
		return &b
	},
}

// BlobType represents Azure blob flavors.
type BlobType string

const (
	BlockBlobType  BlobType = "BlockBlob"
	AppendBlobType BlobType = "AppendBlob"
)

// BlobMetadata records immutable characteristics of a committed blob.
type BlobMetadata struct {
	Account      string
	Container    string
	BlobName     string
	Type         BlobType
	Size         int64
	ETag         string
	LastModified time.Time
}

// BlobEngine is a high-throughput, pool-backed streaming blob storage engine.
type BlobEngine struct {
	mu           sync.RWMutex
	stagedBlocks map[string][]byte // key: account/container/blob:blockID
	committed    map[string][]byte // key: account/container/blob
	metadata     map[string]*BlobMetadata
}

// NewBlobEngine initializes an in-memory streaming blob engine.
func NewBlobEngine() *BlobEngine {
	return &BlobEngine{
		stagedBlocks: make(map[string][]byte),
		committed:    make(map[string][]byte),
		metadata:     make(map[string]*BlobMetadata),
	}
}

func blobKey(account, container, blob string) string {
	return fmt.Sprintf("%s/%s/%s", account, container, blob)
}

func stageKey(account, container, blob, blockID string) string {
	return fmt.Sprintf("%s/%s/%s:%s", account, container, blob, blockID)
}

// StageBlock reads streamed data using pooled buffers and stores the staged block.
func (be *BlobEngine) StageBlock(account, container, blob, blockID string, r io.Reader) (int64, error) {
	bufPtr := bufferPool.Get().(*[]byte)
	defer bufferPool.Put(bufPtr)

	var blockBuf bytes.Buffer
	written, err := io.CopyBuffer(&blockBuf, r, *bufPtr)
	if err != nil {
		return 0, err
	}

	be.mu.Lock()
	defer be.mu.Unlock()
	be.stagedBlocks[stageKey(account, container, blob, blockID)] = blockBuf.Bytes()

	return written, nil
}

// CommitBlockList joins ordered staged blocks into a committed blob and frees staged blocks.
func (be *BlobEngine) CommitBlockList(account, container, blob string, blockIDs []string) (*BlobMetadata, error) {
	be.mu.Lock()
	defer be.mu.Unlock()

	var totalSize int64
	chunks := make([][]byte, 0, len(blockIDs))

	for _, id := range blockIDs {
		k := stageKey(account, container, blob, id)
		data, exists := be.stagedBlocks[k]
		if !exists {
			return nil, fmt.Errorf("staged block %s not found", id)
		}
		chunks = append(chunks, data)
		totalSize += int64(len(data))
	}

	// Concatenate chunks efficiently
	final := make([]byte, totalSize)
	offset := 0
	for _, chunk := range chunks {
		copy(final[offset:], chunk)
		offset += len(chunk)
	}

	// Clean up staged blocks
	for _, id := range blockIDs {
		delete(be.stagedBlocks, stageKey(account, container, blob, id))
	}

	key := blobKey(account, container, blob)
	be.committed[key] = final

	meta := &BlobMetadata{
		Account:      account,
		Container:    container,
		BlobName:     blob,
		Type:         BlockBlobType,
		Size:         totalSize,
		ETag:         fmt.Sprintf(`"%x"`, time.Now().UnixNano()),
		LastModified: time.Now().UTC(),
	}
	be.metadata[key] = meta

	return meta, nil
}

// AppendBlock appends streaming bytes directly to an AppendBlob.
func (be *BlobEngine) AppendBlock(account, container, blob string, r io.Reader) (int64, error) {
	bufPtr := bufferPool.Get().(*[]byte)
	defer bufferPool.Put(bufPtr)

	var newBlock bytes.Buffer
	written, err := io.CopyBuffer(&newBlock, r, *bufPtr)
	if err != nil {
		return 0, err
	}

	be.mu.Lock()
	defer be.mu.Unlock()

	key := blobKey(account, container, blob)
	existing := be.committed[key]
	be.committed[key] = append(existing, newBlock.Bytes()...)

	meta, exists := be.metadata[key]
	if !exists {
		meta = &BlobMetadata{
			Account:   account,
			Container: container,
			BlobName:  blob,
			Type:      AppendBlobType,
		}
		be.metadata[key] = meta
	}
	meta.Size = int64(len(be.committed[key]))
	meta.ETag = fmt.Sprintf(`"%x"`, time.Now().UnixNano())
	meta.LastModified = time.Now().UTC()

	return written, nil
}

// ReadBlobRange streams a byte range directly into the provided writer using zero-copy slicing.
func (be *BlobEngine) ReadBlobRange(account, container, blob string, offset, length int64, w io.Writer) (int64, error) {
	be.mu.RLock()
	defer be.mu.RUnlock()

	key := blobKey(account, container, blob)
	data, exists := be.committed[key]
	if !exists {
		return 0, errors.New("blob not found")
	}

	total := int64(len(data))
	if offset < 0 || offset >= total {
		return 0, errors.New("invalid range offset")
	}

	end := offset + length
	if length <= 0 || end > total {
		end = total
	}

	slice := data[offset:end]
	n, err := w.Write(slice)
	return int64(n), err
}
