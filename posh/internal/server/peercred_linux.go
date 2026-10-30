//go:build linux

package server

import (
	"fmt"
	"net"
	"os"
	"syscall"
)

// verifyPeerCred checks kernel-attested UDS peer credentials via SO_PEERCRED
// over syscall.RawConn.Control (zero cgo). Only the owning UID or root (UID 0)
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
	var cred *syscall.Ucred
	var sockErr error
	ctrlErr := rc.Control(func(fd uintptr) {
		cred, sockErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
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
