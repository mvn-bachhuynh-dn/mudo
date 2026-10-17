//go:build darwin

package proc

import (
	"os"
	"strings"
	"testing"
)

// Runs only on a Mac: checks the sysctl and lsof backends against this test process.
func TestDarwinLiveSelf(t *testing.T) {
	f := FS{}
	st, err := f.Stat(os.Getpid())
	if err != nil || st.PPID != os.Getppid() || st.StartTime == 0 || st.State != "R" {
		t.Fatalf("Stat = %+v, %v", st, err)
	}
	wd, _ := os.Getwd()
	cwd, err := f.Cwd(os.Getpid())
	if err != nil || !strings.HasSuffix(cwd, wd) && !strings.HasSuffix(wd, cwd) {
		t.Fatalf("Cwd = %q, %v; want %q", cwd, err, wd)
	}
	exe, args := f.argv(os.Getpid())
	if exe == "" || len(args) == 0 {
		t.Fatalf("argv = %q %q", exe, args)
	}
	if !f.Alive(os.Getpid(), st.StartTime) || f.Alive(os.Getpid(), st.StartTime+1) {
		t.Fatal("Alive mismatch")
	}
}
