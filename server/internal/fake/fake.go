// Package fake replays a scripted session cycle so the Mac app can be built
// without real agents.
package fake

import (
	"context"
	"time"

	"mudo/internal/model"
	"mudo/internal/store"
)

// Script cycles three sessions through every state. Events carry no PID, so
// the store never ends them by liveness.
func Script() []model.Event {
	ev := func(id, agent, cwd string, k model.EventKind, prompt string) model.Event {
		return model.Event{Agent: agent, SessionID: id, Cwd: cwd, Kind: k, Prompt: prompt}
	}
	const (
		api   = "/home/dev/code/api-gateway"
		web   = "/home/dev/code/web-ui"
		infra = "/home/dev/code/infra-tf"
	)
	return []model.Event{
		ev("fake-1", "claude", api, model.EvSessionStart, ""),
		ev("fake-1", "claude", api, model.EvPrompt, "refactor auth middleware to use JWT"),
		ev("fake-2", "kiro", web, model.EvPrompt, "add a dark mode toggle to settings"),
		ev("fake-3", "claude", infra, model.EvPrompt, "plan the VPC module split"),
		ev("fake-1", "claude", api, model.EvWaiting, ""),
		ev("fake-3", "claude", infra, model.EvStop, ""),
		ev("fake-1", "claude", api, model.EvTool, ""),
		ev("fake-2", "kiro", web, model.EvStop, ""),
		ev("fake-1", "claude", api, model.EvStop, ""),
		ev("fake-2", "kiro", web, model.EvSessionEnd, ""),
	}
}

// Drive applies Script in a loop, one event per step, until ctx ends.
func Drive(ctx context.Context, st *store.Store, step time.Duration) {
	script := Script()
	for i := 0; ; i = (i + 1) % len(script) {
		st.Apply(script[i])
		select {
		case <-ctx.Done():
			return
		case <-time.After(step):
		}
	}
}
