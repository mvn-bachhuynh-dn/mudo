package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"mudo/internal/api"
	"mudo/internal/fake"
	"mudo/internal/store"
)

func runFake(args []string) error {
	fs := flag.NewFlagSet("fake", flag.ExitOnError)
	addr := fs.String("addr", "0.0.0.0:7879", "listen address")
	token := fs.String("token", "fake-token", "bearer token")
	step := fs.Duration("step", 3*time.Second, "delay between scripted events")
	_ = fs.Parse(args)

	st := store.New(store.Options{Host: "fake"})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go fake.Drive(ctx, st, *step)

	srv := &http.Server{
		Addr:        *addr,
		BaseContext: func(net.Listener) context.Context { return ctx },
		Handler: api.Client(st, api.ClientOptions{
			Token: *token, Host: "fake", Version: version, Started: time.Now(), Now: time.Now,
			PingEvery: 15 * time.Second, SubBuffer: 64,
		}),
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	fmt.Printf("fake mudod on %s, token %q, step %s\n", *addr, *token, *step)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
