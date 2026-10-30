//go:build darwin

package server

import (
	"fmt"
	"net"
	"os"
	"syscall"
	"unsafe"
)

// xucred mirrors macOS's struct xucred (<sys/ucred.h>) returned by
// getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ...). Zero cgo required.
type xucred struct {
	Version uint32
	Uid     uint32
	Ngroups int16
	Groups  [16]uint32
}

const (
	solLocal      = 0
	localPeerCred = 0x001
)

// verifyPeerCred checks kernel-attested UDS peer credentials via
// syscall.RawConn.Control (zero cgo). Only the owning UID or root (UID 0)
// is admitted across the local membrane socket.
func verifyPeerCred(c net.Conn) error {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return nil
	}
	rc, err := uc.SyscallConn()
	if err != nil {
		return fmt.Errorf("peercred syscallconn: %w", err)
	}
	var cred xucred
	var sockErr error
	ctrlErr := rc.Control(func(fd uintptr) {
		credLen := uint32(unsafe.Sizeof(cred))
		_, _, errno := syscall.Syscall6(
			syscall.SYS_GETSOCKOPT,
			fd,
			uintptr(solLocal),
			uintptr(localPeerCred),
			uintptr(unsafe.Pointer(&cred)),
			uintptr(unsafe.Pointer(&credLen)),
			0,
		)
		if errno != 0 {
			sockErr = errno
		}
	})
	if ctrlErr != nil {
		return fmt.Errorf("peercred control: %w", ctrlErr)
	}
	if sockErr != nil {
		return fmt.Errorf("peercred getsockopt: %w", sockErr)
	}
	euid := uint32(os.Geteuid())
	if cred.Uid != euid && cred.Uid != 0 {
		return fmt.Errorf("peercred UID %d unauthorized (server euid=%d)", cred.Uid, euid)
	}
	return nil
}
