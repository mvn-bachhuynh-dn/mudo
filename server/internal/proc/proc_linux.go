//go:build linux

package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

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

// Cwd returns the working directory of pid (the /proc/<pid>/cwd symlink).
func (f FS) Cwd(pid int) (string, error) {
	return os.Readlink(filepath.Join(f.Root, strconv.Itoa(pid), "cwd"))
}

// argv returns the /proc/<pid>/exe target (empty when unreadable) and the
// NUL-separated command line.
func (f FS) argv(pid int) (string, []string) {
	exe, _ := os.Readlink(filepath.Join(f.Root, strconv.Itoa(pid), "exe"))
	b, err := os.ReadFile(filepath.Join(f.Root, strconv.Itoa(pid), "cmdline"))
	if err != nil || len(b) == 0 {
		return exe, nil
	}
	return exe, strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00")
}

func (f FS) cmdline(pid int) string {
	b, err := os.ReadFile(filepath.Join(f.Root, strconv.Itoa(pid), "cmdline"))
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(b), "\x00", " ")
}
