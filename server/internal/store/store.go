// Package store holds live sessions, broadcasts changes and persists them.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"mudo/internal/machine"
	"mudo/internal/model"
)

var ErrNotFound = errors.New("session not found")

type MsgType string

const (
	MsgUpsert MsgType = "upsert"
	MsgRemove MsgType = "remove"
)

type Msg struct {
	Type    MsgType
	Session model.Session
	ID      string
}

type Options struct {
	Host     string
	Path     string // state file; empty disables persistence
	Now      func() time.Time
	Alive    func(pid int, start uint64) bool
	EndedTTL time.Duration
}

// Store is safe for concurrent use. Every mutation broadcasts while holding
// the lock, so all subscribers see changes in the same order.
type Store struct {
	opts     Options
	mu       sync.Mutex
	sessions map[string]model.Session
	subs     map[chan Msg]struct{}
	dirty    chan struct{}
}

func New(o Options) *Store {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Alive == nil {
		o.Alive = func(int, uint64) bool { return true }
	}
	if o.EndedTTL == 0 {
		o.EndedTTL = time.Hour
	}
	return &Store{
		opts:     o,
		sessions: map[string]model.Session{},
		subs:     map[chan Msg]struct{}{},
		dirty:    make(chan struct{}, 1),
	}
}

func (s *Store) Load() error {
	if s.opts.Path == "" {
		return nil
	}
	data, err := os.ReadFile(s.opts.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var list []model.Session
	if err := json.Unmarshal(data, &list); err != nil {
		bad := s.opts.Path + ".corrupt-" + s.now().Format("20060102-150405")
		return os.Rename(s.opts.Path, bad)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, x := range list {
		s.sessions[x.ID] = x
	}
	return nil
}

func (s *Store) Apply(ev model.Event) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var prev *model.Session
	if cur, ok := s.sessions[ev.SessionID]; ok {
		prev = &cur
	}
	next, changed := machine.Apply(prev, ev, s.opts.Host, s.now())
	if changed {
		s.put(next)
	}
}

func (s *Store) Ack(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, ok := s.sessions[id]
	if !ok {
		return ErrNotFound
	}
	next, err := machine.Ack(cur, s.now())
	if err != nil {
		return err
	}
	s.put(next)
	return nil
}

func (s *Store) Snapshot() []model.Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked()
}

// Subscribe registers a listener and returns the snapshot it starts from.
// The channel is closed if the listener falls behind by more than buf
// messages, or when cancel is called.
func (s *Store) Subscribe(buf int) (<-chan Msg, []model.Session, func()) {
	ch := make(chan Msg, buf)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	snap := s.snapshotLocked()
	s.mu.Unlock()
	cancel := func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if _, ok := s.subs[ch]; ok {
			delete(s.subs, ch)
			close(ch)
		}
	}
	return ch, snap, cancel
}

// Sweep ends sessions whose process is gone and deletes long-ended ones.
func (s *Store) Sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for id, x := range s.sessions {
		switch {
		case x.State != model.StateEnded && x.PID != 0 && !s.opts.Alive(x.PID, x.PIDStart):
			s.put(machine.End(x, now))
		case x.State == model.StateEnded && now.Sub(x.StateSince) >= s.opts.EndedTTL:
			delete(s.sessions, id)
			s.broadcast(Msg{Type: MsgRemove, ID: id})
			s.markDirty()
		}
	}
}

// Flush writes the state file atomically.
func (s *Store) Flush() error {
	if s.opts.Path == "" {
		return nil
	}
	data, err := json.MarshalIndent(s.Snapshot(), "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.opts.Path), 0o700); err != nil {
		return err
	}
	tmp := s.opts.Path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp, s.opts.Path)
}

// Run sweeps every sweepEvery and writes the state file 200 ms after the
// last change. It flushes once more and returns when ctx is cancelled.
func (s *Store) Run(ctx context.Context, sweepEvery time.Duration, onErr func(error)) {
	s.Sweep()
	ticker := time.NewTicker(sweepEvery)
	defer ticker.Stop()
	var debounce <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			if err := s.Flush(); err != nil {
				onErr(err)
			}
			return
		case <-ticker.C:
			s.Sweep()
		case <-s.dirty:
			if debounce == nil {
				debounce = time.After(200 * time.Millisecond)
			}
		case <-debounce:
			debounce = nil
			if err := s.Flush(); err != nil {
				onErr(err)
			}
		}
	}
}

func (s *Store) now() time.Time { return s.opts.Now().UTC() }

func (s *Store) put(x model.Session) {
	s.sessions[x.ID] = x
	s.broadcast(Msg{Type: MsgUpsert, Session: x, ID: x.ID})
	s.markDirty()
}

func (s *Store) broadcast(m Msg) {
	for ch := range s.subs {
		select {
		case ch <- m:
		default:
			delete(s.subs, ch)
			close(ch)
		}
	}
}

func (s *Store) markDirty() {
	select {
	case s.dirty <- struct{}{}:
	default:
	}
}

func (s *Store) snapshotLocked() []model.Session {
	list := make([]model.Session, 0, len(s.sessions))
	for _, x := range s.sessions {
		list = append(list, x)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	return list
}
