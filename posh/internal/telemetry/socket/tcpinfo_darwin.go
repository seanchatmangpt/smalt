//go:build darwin

package socket

import (
	"net"
	"syscall"
	"unsafe"
)

// TCP_CONNECTION_INFO option on Darwin (see <netinet/tcp.h>)
const tcpConnectionInfo = 0x106

type darwinTCPConnectionInfo struct {
	State               uint8
	SndWscale           uint8
	RcvWscale           uint8
	_                   uint8
	Options             uint32
	Rto                 uint32
	Maxseg              uint32
	SndSsthresh         uint32
	SndCwnd             uint32
	SndWnd              uint32
	SndSbbytes          uint32
	RcvWnd              uint32
	Rttcur              uint32
	Srtt                uint32 // Smoothed RTT in ms
	Rttvar              uint32
	_                   [4]byte
	Txpackets           uint64
	Txbytes             uint64
	Txretransmitbytes   uint64
	Rxpackets           uint64
	Rxbytes             uint64
	Rxoutoforderbytes   uint64
	Txretransmitpackets uint64 // Retransmitted packets
}

// InspectTCPInfo extracts kernel socket connection info on Darwin.
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
		info darwinTCPConnectionInfo
		sockErr error
	)

	err = rawConn.Control(func(fd uintptr) {
		vallen := uint32(unsafe.Sizeof(info))
		_, _, errno := syscall.Syscall6(
			syscall.SYS_GETSOCKOPT,
			fd,
			syscall.IPPROTO_TCP,
			tcpConnectionInfo,
			uintptr(unsafe.Pointer(&info)),
			uintptr(unsafe.Pointer(&vallen)),
			0,
		)
		if errno != 0 {
			sockErr = errno
		}
	})
	if err != nil {
		return 0, 0, err
	}
	if sockErr != nil {
		return 0, 0, sockErr
	}

	return uint32(info.Txretransmitpackets), info.Srtt * 1000, nil
}
