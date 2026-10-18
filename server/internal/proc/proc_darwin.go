//go:build darwin

package proc

import (
	"context"
	"os/exec"
	"strconv"
	"time"

	"golang.org/x/sys/unix"
)

// FS on darwin reads the kernel through sysctl; Root is ignored.
func (f FS) Stat(pid int) (Stat, error) {
	k, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return Stat{}, err
	}
	comm := unix.ByteSliceToString(k.Proc.P_comm[:])
	return statFromKinfo(comm, int(k.Eproc.Ppid), k.Proc.P_starttime.Sec, int64(k.Proc.P_starttime.Usec), k.Proc.P_stat), nil
}

func (f FS) Cwd(pid int) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return "", err
	}
	return parseLsofCwd(string(out))
}

func (f FS) argv(pid int) (string, []string) {
	b, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil
	}
	exe, args, err := parseProcargs2(b)
	if err != nil {
		return "", nil
	}
	return exe, args
}
