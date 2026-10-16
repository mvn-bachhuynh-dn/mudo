package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// WriteFakeCwd points /proc/<pid>/cwd at target, like the real symlink.
func WriteFakeCwd(root string, pid int, target string) error {
	return os.Symlink(target, filepath.Join(root, strconv.Itoa(pid), "cwd"))
}

// WriteFakeProcess writes a minimal /proc/<pid>/{stat,cmdline} under root so
// tests in any package can build a fake process tree.
func WriteFakeProcess(root string, pid int, comm string, ppid int, start uint64, cmdline string) error {
	dir := filepath.Join(root, strconv.Itoa(pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// Fields 3..21 then starttime (field 22), then two trailing fields.
	stat := fmt.Sprintf("%d (%s) S %d 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %d 0 0\n", pid, comm, ppid, start)
	if err := os.WriteFile(filepath.Join(dir, "stat"), []byte(stat), 0o644); err != nil {
		return err
	}
	args := strings.ReplaceAll(cmdline, " ", "\x00") + "\x00"
	return os.WriteFile(filepath.Join(dir, "cmdline"), []byte(args), 0o644)
}
