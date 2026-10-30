//go:build !darwin && !linux

package doctor

func getSocketBufferStats(fd uintptr) (rcvbuf, sndbuf, rcvQueueDepth, sndQueueDepth int, err error) {
	return 65536, 65536, 0, 0, nil
}

func countOpenFileDescriptors() (uint64, error) {
	return 10, nil
}
