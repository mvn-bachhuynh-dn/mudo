package main

import (
	"context"
	"net"
	"syscall"
)

// listenFreebind listens on addr even when its IP is not assigned yet, such
// as a Tailscale address at boot.
func listenFreebind(ctx context.Context, addr string) (net.Listener, error) {
	lc := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var serr error
		if err := c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_FREEBIND, 1)
		}); err != nil {
			return err
		}
		return serr
	}}
	return lc.Listen(ctx, "tcp", addr)
}
