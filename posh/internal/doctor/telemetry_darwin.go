//go:build darwin

package doctor

import (
	"os"
	"syscall"
	"unsafe"
)

// fionread is _IOR('f', 127, int) on Darwin (<sys/filio.h>).
const fionread = 0x4004667f

// getSocketBufferStats queries kernel socket buffer capacities and queue depths on Darwin.
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

	// Darwin FIONREAD queries unread bytes in the socket receive buffer.
	var unread uint32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, fionread, uintptr(unsafe.Pointer(&unread)))
	if errno == 0 {
		rcvQueueDepth = int(unread)
	}

	return rcvbuf, sndbuf, rcvQueueDepth, 0, nil
}

// countOpenFileDescriptors counts open file descriptors by reading /dev/fd on Darwin.
func countOpenFileDescriptors() (uint64, error) {
	f, err := os.Open("/dev/fd")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	// Readdirnames returns entry names without performing lstat on /dev/fd entries,
	// preventing "bad file descriptor" errors from ephemeral descriptors.
	names, err := f.Readdirnames(-1)
	if err != nil {
		return 0, err
	}
	return uint64(len(names)), nil
}
