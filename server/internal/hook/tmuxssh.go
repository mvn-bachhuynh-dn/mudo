package hook

import (
	"bytes"
	"strconv"
	"strings"
)

// PickClientPID returns the pid of the most recently active client in
// `tmux list-clients -F '#{client_activity} #{client_pid}'` output, or "".
// Malformed lines are skipped.
func PickClientPID(listClients string) string {
	var best int64 = -1
	pid := ""
	for _, line := range strings.Split(listClients, "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		act, err := strconv.ParseInt(f[0], 10, 64)
		if err != nil {
			continue
		}
		if _, err := strconv.Atoi(f[1]); err != nil {
			continue
		}
		if act > best {
			best, pid = act, f[1]
		}
	}
	return pid
}

// SSHFromEnviron returns SSH_CONNECTION from a NUL-separated environ
// (/proc/<pid>/environ), or "".
func SSHFromEnviron(b []byte) string {
	for _, kv := range bytes.Split(b, []byte{0}) {
		if v, ok := bytes.CutPrefix(kv, []byte("SSH_CONNECTION=")); ok {
			return string(v)
		}
	}
	return ""
}
