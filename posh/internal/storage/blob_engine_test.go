package storage_test

import (
	"bytes"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/storage"
)

func TestBlobEngine_StageAndCommitBlockList(t *testing.T) {
	t.Parallel()

	engine := storage.NewBlobEngine()
	account := "testaccount"
	container := "testcontainer"
	blob := "file.bin"

	block1 := []byte("first-block-data-64k-payload-")
	block2 := []byte("second-block-data-more-bytes-")

	_, err := engine.StageBlock(account, container, blob, "block001", bytes.NewReader(block1))
	require.NoError(t, err)

	_, err = engine.StageBlock(account, container, blob, "block002", bytes.NewReader(block2))
	require.NoError(t, err)

	meta, err := engine.CommitBlockList(account, container, blob, []string{"block001", "block002"})
	require.NoError(t, err)
	require.Equal(t, int64(len(block1)+len(block2)), meta.Size)
	require.Equal(t, storage.BlockBlobType, meta.Type)

	// Verify range read
	var out bytes.Buffer
	n, err := engine.ReadBlobRange(account, container, blob, 0, int64(len(block1)), &out)
	require.NoError(t, err)
	require.Equal(t, int64(len(block1)), n)
	require.Equal(t, string(block1), out.String())
}

func TestBlobEngine_AppendBlob(t *testing.T) {
	t.Parallel()

	engine := storage.NewBlobEngine()
	account := "sa"
	container := "logs"
	blob := "app.log"

	chunk1 := "2026-10-30 line 1\n"
	chunk2 := "2026-10-30 line 2\n"

	_, err := engine.AppendBlock(account, container, blob, strings.NewReader(chunk1))
	require.NoError(t, err)

	_, err = engine.AppendBlock(account, container, blob, strings.NewReader(chunk2))
	require.NoError(t, err)

	var full bytes.Buffer
	n, err := engine.ReadBlobRange(account, container, blob, 0, -1, &full)
	require.NoError(t, err)
	require.Equal(t, int64(len(chunk1)+len(chunk2)), n)
	require.Equal(t, chunk1+chunk2, full.String())
}
