//go:build !linux && !darwin

package socket

import "net"

// InspectTCPInfo provides a safe fallback for unsupported platforms.
func InspectTCPInfo(conn net.Conn) (retrans uint32, rttUs uint32, err error) {
	return 0, 0, nil
}
