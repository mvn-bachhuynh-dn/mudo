//go:build !linux

package main

import (
	"context"
	"net"
)

// listenFreebind is a plain listen off Linux; IP_FREEBIND is Linux-only and
// the darwin daemon binds loopback.
func listenFreebind(ctx context.Context, addr string) (net.Listener, error) {
	return (&net.ListenConfig{}).Listen(ctx, "tcp", addr)
}
