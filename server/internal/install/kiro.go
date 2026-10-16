package install

import "encoding/json"

type kiroAction struct {
	Type    string `json:"type"`
	Command string `json:"command"`
}

type kiroHook struct {
	Name    string     `json:"name"`
	Trigger string     `json:"trigger"`
	Action  kiroAction `json:"action"`
	Timeout int        `json:"timeout"`
	Enabled bool       `json:"enabled"`
}

// KiroHooks returns ~/.kiro/hooks/mudo.json in the Kiro CLI V3 hook format.
func KiroHooks(command string) []byte {
	var hooks []kiroHook
	for _, trigger := range []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"} {
		hooks = append(hooks, kiroHook{
			Name: "mudo-" + trigger, Trigger: trigger,
			Action:  kiroAction{Type: "command", Command: command},
			Timeout: 2, Enabled: true,
		})
	}
	data, _ := json.MarshalIndent(struct {
		Version string     `json:"version"`
		Hooks   []kiroHook `json:"hooks"`
	}{"v1", hooks}, "", "  ")
	return append(data, '\n')
}
