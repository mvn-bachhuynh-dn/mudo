// Package proc finds and watches agent processes: through /proc on Linux and
// sysctl/lsof on macOS.
package proc

import (
	"path/filepath"
	"strings"
)

type FS struct {
	Root string
}

type Stat struct {
	Comm      string
	State     string
	PPID      int
	StartTime uint64
}

// FindAgent walks up from pid `from` to the agent's own process and reports
// found=true. If none is found it returns `from` itself with found=false.
func (f FS) FindAgent(from int, agent string) (pid int, start uint64, found bool) {
	pid = from
	for i := 0; i < 16 && pid > 1; i++ {
		st, err := f.Stat(pid)
		if err != nil {
			break
		}
		if f.isAgent(pid, st.Comm, agent) {
			return pid, st.StartTime, true
		}
		pid = st.PPID
	}
	st, err := f.Stat(from)
	if err != nil {
		return from, 0, false
	}
	return from, st.StartTime, false
}

// Alive reports whether pid exists, is not a zombie, and (when start is
// known) is the same process that was first seen.
func (f FS) Alive(pid int, start uint64) bool {
	st, err := f.Stat(pid)
	if err != nil || st.State == "Z" {
		return false
	}
	return start == 0 || st.StartTime == start
}

func (f FS) isAgent(pid int, comm, agent string) bool {
	switch agent {
	case "claude":
		if comm == "claude" {
			return true
		}
		cmd := f.cmdline(pid)
		if comm == "node" && strings.Contains(cmd, "claude") {
			return true
		}
		// The native installer runs a binary named after its version, so
		// comm is e.g. "2.1.144"; argv0 or the versions path gives it away.
		exe, args := f.argv(pid)
		if len(args) > 0 && filepath.Base(args[0]) == "claude" {
			return true
		}
		return strings.Contains(exe, "/claude/versions/") || strings.Contains(cmd, "/claude/versions/")
	case "kiro":
		return strings.HasPrefix(comm, "kiro")
	}
	return false
}
