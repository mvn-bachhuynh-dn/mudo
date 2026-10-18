package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"mudo/internal/api"
	"mudo/internal/config"
	"mudo/internal/proc"
	"mudo/internal/store"
)

func runServe(args []string) error {
	p, err := homePaths()
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	cfgPath := fs.String("config", p.Config, "config file")
	statePath := fs.String("state", p.State, "state file")
	_ = fs.Parse(args)

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		return err
	}
	host := cfg.Host
	if host == "" {
		host, _ = os.Hostname()
	}
	logger := log.New(os.Stderr, "mudod: ", log.LstdFlags)

	pfs := proc.FS{Root: "/proc"}
	st := store.New(store.Options{Host: host, Path: *statePath, Alive: pfs.Alive, Cwd: pfs.Cwd})
	if err := st.Load(); err != nil {
		return fmt.Errorf("load state: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	stored := make(chan struct{})
	go func() {
		st.Run(ctx, 10*time.Second, func(err error) { logger.Printf("persist: %v", err) })
		close(stored)
	}()

	base := func(net.Listener) context.Context { return ctx }
	ingest := &http.Server{Addr: cfg.IngestAddr, Handler: api.Ingest(st, cfg.IngestAddr), BaseContext: base}
	client := &http.Server{Addr: cfg.APIAddr, BaseContext: base, ReadHeaderTimeout: 10 * time.Second, Handler: api.Client(st, api.ClientOptions{
		Token: cfg.Token, Host: host, Version: version, Started: time.Now(), Now: time.Now,
		PingEvery: 15 * time.Second, SubBuffer: 64,
	})}

	errc := make(chan error, 2)
	apiLn, err := listenFreebind(ctx, cfg.APIAddr)
	if err != nil {
		stop()
		<-stored
		if err := st.Flush(); err != nil {
			logger.Printf("persist: %v", err)
		}
		return err
	}
	go func() { errc <- ingest.ListenAndServe() }()
	go func() { errc <- client.Serve(apiLn) }()
	logger.Printf("ingest on %s, api on %s", cfg.IngestAddr, cfg.APIAddr)

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-errc:
		stop()
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = ingest.Shutdown(shutdownCtx)
	_ = client.Shutdown(shutdownCtx)
	<-stored
	if runErr != nil && !errors.Is(runErr, http.ErrServerClosed) {
		return runErr
	}
	return nil
}
