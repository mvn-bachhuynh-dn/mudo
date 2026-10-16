// Package hook turns one agent hook invocation into a model.Event.
package hook

import (
	"encoding/json"
	"fmt"
	"strings"

	"mudo/internal/model"
)

const promptLimit = 80

// Normalize decodes a Claude Code or Kiro CLI hook payload. It returns
// ok=false for events MuDo does not track.
func Normalize(agent string, payload []byte) (model.Event, bool, error) {
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		return model.Event{}, false, fmt.Errorf("hook: decode payload: %w", err)
	}
	kind, ok := kindFor(str(m, "hook_event_name", "hookEventName", "event"), str(m, "notification_type", "notificationType"))
	if !ok {
		return model.Event{}, false, nil
	}
	ev := model.Event{
		Agent:     agent,
		SessionID: str(m, "session_id", "sessionId"),
		Cwd:       str(m, "cwd"),
		Kind:      kind,
	}
	if kind == model.EvPrompt {
		ev.Prompt = Truncate(str(m, "prompt"), promptLimit)
	}
	return ev, true, nil
}

// Truncate collapses whitespace and cuts s to at most n runes, ending with "…" when cut.
func Truncate(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func kindFor(name, notification string) (model.EventKind, bool) {
	switch strings.ToLower(name) {
	case "sessionstart", "agentspawn":
		return model.EvSessionStart, true
	case "userpromptsubmit":
		return model.EvPrompt, true
	case "pretooluse":
		return model.EvTool, true
	case "notification":
		if notification == "permission_prompt" || notification == "elicitation_dialog" {
			return model.EvWaiting, true
		}
	case "stop":
		return model.EvStop, true
	case "sessionend":
		return model.EvSessionEnd, true
	}
	return "", false
}

func str(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}
