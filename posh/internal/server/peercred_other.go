//go:build !darwin && !linux

package server

import "net"

func verifyPeerCred(c net.Conn) error { return nil }
