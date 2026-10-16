// Package proc reads the Linux /proc filesystem to find and watch agent processes.
package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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

func (f FS) Stat(pid int) (Stat, error) {
	data, err := os.ReadFile(filepath.Join(f.Root, strconv.Itoa(pid), "stat"))
	if err != nil {
		return Stat{}, err
	}
	s := string(data)
	open, end := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
	if open < 0 || end < open {
		return Stat{}, fmt.Errorf("proc: malformed stat for %d", pid)
	}
	// fields[0] is stat field 3; field N is fields[N-3].
	fields := strings.Fields(s[end+1:])
	if len(fields) < 20 {
		return Stat{}, fmt.Errorf("proc: short stat for %d", pid)
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return Stat{}, fmt.Errorf("proc: ppid for %d: %w", pid, err)
	}
	start, err := strconv.ParseUint(fields[19], 10, 64)
	if err != nil {
		return Stat{}, fmt.Errorf("proc: starttime for %d: %w", pid, err)
	}
	return Stat{Comm: s[open+1 : end], State: fields[0], PPID: ppid, StartTime: start}, nil
}

// FindAgent walks up from pid `from` to the agent's own process. If none is
// found it returns `from` itself.
func (f FS) FindAgent(from int, agent string) (int, uint64) {
	pid := from
	for i := 0; i < 16 && pid > 1; i++ {
		st, err := f.Stat(pid)
		if err != nil {
			break
		}
		if f.isAgent(pid, st.Comm, agent) {
			return pid, st.StartTime
		}
		pid = st.PPID
	}
	st, err := f.Stat(from)
	if err != nil {
		return from, 0
	}
	return from, st.StartTime
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
		return comm == "node" && strings.Contains(f.cmdline(pid), "claude")
	case "kiro":
		return strings.HasPrefix(comm, "kiro")
	}
	return false
}

func (f FS) cmdline(pid int) string {
	b, err := os.ReadFile(filepath.Join(f.Root, strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(b), "\x00", " ")
}
