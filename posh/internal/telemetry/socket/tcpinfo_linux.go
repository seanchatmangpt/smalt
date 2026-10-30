//go:build linux

package socket

import (
	"net"
	"syscall"
)

// InspectTCPInfo extracts kernel TCP_INFO metrics on Linux without external dependencies.
func InspectTCPInfo(conn net.Conn) (retrans uint32, rttUs uint32, err error) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return 0, 0, nil
	}

	rawConn, err := tcpConn.SyscallConn()
	if err != nil {
		return 0, 0, err
	}

	var (
		tcpi *syscall.TCPInfo
		sockErr error
	)

	err = rawConn.Control(func(fd uintptr) {
		tcpi, sockErr = syscall.GetsockoptTCPInfo(int(fd), syscall.SOL_TCP, syscall.TCP_INFO)
	})
	if err != nil {
		return 0, 0, err
	}
	if sockErr != nil {
		return 0, 0, sockErr
	}

	return tcpi.Retrans, tcpi.Rtt, nil
}
