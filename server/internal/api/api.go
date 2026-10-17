// Package api serves the localhost ingest endpoint and the client API (spec section 5).
package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"time"

	"mudo/internal/machine"
	"mudo/internal/model"
	"mudo/internal/store"
)

// Ingest accepts events from `mudod hook`. Bind it to localhost only.
// addr is the configured ingest host:port; requests from browsers (an Origin
// header, a non-JSON body or a DNS-rebound Host) are refused.
func Ingest(st *store.Store, addr string) http.Handler {
	mux := ingestMux(st)
	allowed := map[string]bool{addr: true}
	if _, port, err := net.SplitHostPort(addr); err == nil {
		allowed["localhost:"+port] = true
		allowed["127.0.0.1:"+port] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if r.Header.Get("Origin") != "" || !allowed[r.Host] || mt != "application/json" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func ingestMux(st *store.Store) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /event", func(w http.ResponseWriter, r *http.Request) {
		var ev model.Event
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&ev); err != nil {
			http.Error(w, "bad event", http.StatusBadRequest)
			return
		}
		if ev.Agent == "" || ev.SessionID == "" || ev.Kind == "" {
			http.Error(w, "missing agent, session_id or event", http.StatusBadRequest)
			return
		}
		st.Apply(ev)
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}

type ClientOptions struct {
	Token     string
	Host      string
	Version   string
	Started   time.Time
	Now       func() time.Time
	PingEvery time.Duration
	SubBuffer int
}

// Client serves the token-protected API used by the Mac app.
func Client(st *store.Store, o ClientOptions) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"version":  o.Version,
			"uptime_s": int(o.Now().Sub(o.Started).Seconds()),
		})
	})
	mux.HandleFunc("POST /v1/sessions/{id}/ack", func(w http.ResponseWriter, r *http.Request) {
		switch err := st.Ack(r.PathValue("id")); {
		case err == nil:
			w.WriteHeader(http.StatusNoContent)
		case errors.Is(err, store.ErrNotFound):
			http.Error(w, err.Error(), http.StatusNotFound)
		case errors.Is(err, machine.ErrNotDone):
			http.Error(w, err.Error(), http.StatusConflict)
		default:
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})
	mux.HandleFunc("GET /v1/stream", stream(st, o))
	return requireToken(o.Token, mux)
}

type snapshotMsg struct {
	ServerNow time.Time       `json:"server_now"`
	Host      string          `json:"host"`
	Sessions  []model.Session `json:"sessions"`
}

type upsertMsg struct {
	ServerNow time.Time     `json:"server_now"`
	Session   model.Session `json:"session"`
}

type removeMsg struct {
	ServerNow time.Time `json:"server_now"`
	ID        string    `json:"id"`
}

type pingMsg struct {
	ServerNow time.Time `json:"server_now"`
}

func stream(st *store.Store, o ClientOptions) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "text/event-stream")
		h.Set("Cache-Control", "no-cache")
		h.Set("Connection", "keep-alive")

		ch, snap, cancel := st.Subscribe(o.SubBuffer)
		defer cancel()
		if err := writeEvent(w, "snapshot", snapshotMsg{ServerNow: o.Now().UTC(), Host: o.Host, Sessions: snap}); err != nil {
			return
		}
		flusher.Flush()

		ping := time.NewTicker(o.PingEvery)
		defer ping.Stop()
		for {
			var err error
			select {
			case <-r.Context().Done():
				return
			case <-ping.C:
				err = writeEvent(w, "ping", pingMsg{ServerNow: o.Now().UTC()})
			case m, ok := <-ch:
				if !ok {
					return // fell behind; the client reconnects and gets a fresh snapshot
				}
				switch m.Type {
				case store.MsgUpsert:
					err = writeEvent(w, "upsert", upsertMsg{ServerNow: o.Now().UTC(), Session: m.Session})
				case store.MsgRemove:
					err = writeEvent(w, "remove", removeMsg{ServerNow: o.Now().UTC(), ID: m.ID})
				}
			}
			if err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func writeEvent(w io.Writer, name string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", name, data)
	return err
}

func requireToken(token string, next http.Handler) http.Handler {
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), want) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
