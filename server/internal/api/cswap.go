package api

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// CswapRunner runs `cswap <args>` and returns its stdout. The args are built by this package
// only (`list --json`, `switch <digits>`), never taken from a request as free text.
type CswapRunner func(ctx context.Context, args ...string) ([]byte, error)

var accountNumber = regexp.MustCompile(`^[0-9]{1,3}$`)

// FindCswap returns the first executable cswap in the fixed install locations, or "".
// The daemon runs under systemd/launchd with a minimal PATH, so PATH is not searched.
func FindCswap(home string) string {
	for _, p := range []string{
		filepath.Join(home, ".local", "bin", "cswap"),
		"/usr/local/bin/cswap",
		"/opt/homebrew/bin/cswap",
	} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// ExecCswap runs the binary at path with a 20 s limit and no stdin.
func ExecCswap(path string) CswapRunner {
	return func(ctx context.Context, args ...string) ([]byte, error) {
		ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, path, args...)
		var out, errb bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &errb
		if err := cmd.Run(); err != nil {
			msg := firstLine(errb.String())
			if msg == "" {
				msg = firstLine(out.String())
			}
			if msg == "" {
				msg = err.Error()
			}
			return nil, errors.New(msg)
		}
		return out.Bytes(), nil
	}
}

// firstLine is the first non-empty line, skipping cswap's upgrade notice.
func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if l != "" && !strings.HasPrefix(l, "A newer version") {
			return l
		}
	}
	return ""
}

func cswapRoutes(mux *http.ServeMux, run CswapRunner) {
	var mu sync.Mutex // cswap rewrites credential files: one command at a time
	mux.HandleFunc("GET /v1/cswap", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		out, err := run(r.Context(), "list", "--json")
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
	})
	mux.HandleFunc("POST /v1/cswap/switch/{number}", func(w http.ResponseWriter, r *http.Request) {
		n := r.PathValue("number")
		if !accountNumber.MatchString(n) {
			http.Error(w, "bad account number", http.StatusBadRequest)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if _, err := run(r.Context(), "switch", n); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
