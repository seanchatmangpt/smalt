//go:build linux

package doctor

import (
	"os"
	"syscall"
	"unsafe"
)

// getSocketBufferStats queries kernel socket buffer capacities and queue depths on Linux.
func getSocketBufferStats(fd uintptr) (rcvbuf, sndbuf, rcvQueueDepth, sndQueueDepth int, err error) {
	rcv, err1 := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF)
	snd, err2 := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_SNDBUF)
	if err1 != nil {
		return 0, 0, 0, 0, err1
	}
	if err2 != nil {
		return 0, 0, 0, 0, err2
	}
	rcvbuf = rcv
	sndbuf = snd

	// Linux TIOCINQ (SIOCINQ) queries unread bytes in the receive queue.
	var unread int
	_, _, errno1 := syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(syscall.TIOCINQ), uintptr(unsafe.Pointer(&unread)))
	if errno1 == 0 {
		rcvQueueDepth = unread
	}

	// Linux TIOCOUTQ (SIOCOUTQ) queries unsent bytes in the send queue.
	var unsent int
	_, _, errno2 := syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(syscall.TIOCOUTQ), uintptr(unsafe.Pointer(&unsent)))
	if errno2 == 0 {
		sndQueueDepth = unsent
	}

	return rcvbuf, sndbuf, rcvQueueDepth, sndQueueDepth, nil
}

// countOpenFileDescriptors counts open file descriptors by reading /proc/self/fd on Linux.
func countOpenFileDescriptors() (uint64, error) {
	f, err := os.Open("/proc/self/fd")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	names, err := f.Readdirnames(-1)
	if err != nil {
		return 0, err
	}
	return uint64(len(names)), nil
}
