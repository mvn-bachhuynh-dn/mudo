package proc

import (
	"os"
	"path/filepath"
	"testing"
)

func fakeTree(t *testing.T) FS {
	t.Helper()
	root := t.TempDir()
	procs := []struct {
		pid, ppid int
		comm      string
		start     uint64
		cmdline   string
	}{
		{100, 1, "code-server", 10, "node /usr/lib/code-server"},
		{200, 100, "bash", 20, "/bin/bash"},
		{300, 200, "claude", 30, "claude"},
		{400, 300, "sh", 40, "sh -c mudod hook --agent claude"},
		{500, 200, "node", 50, "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"},
		{600, 500, "sh", 60, "sh -c mudod hook"},
		{700, 200, "kiro-cli-chat", 70, "kiro-cli chat"},
		{800, 700, "sh", 80, "sh -c mudod hook --agent kiro"},
		{900, 200, "tmux: server", 90, "tmux"},
	}
	for _, p := range procs {
		if err := WriteFakeProcess(root, p.pid, p.comm, p.ppid, p.start, p.cmdline); err != nil {
			t.Fatal(err)
		}
	}
	return FS{Root: root}
}

func TestStatParsesCommWithSpaces(t *testing.T) {
	st, err := fakeTree(t).Stat(900)
	if err != nil {
		t.Fatal(err)
	}
	if st.Comm != "tmux: server" || st.PPID != 200 || st.StartTime != 90 || st.State != "S" {
		t.Fatalf("stat = %+v", st)
	}
}

func TestFindAgent(t *testing.T) {
	fs := fakeTree(t)
	cases := []struct {
		name      string
		from      int
		agent     string
		pid       int
		startTime uint64
	}{
		{"claude binary", 400, "claude", 300, 30},
		{"claude via node", 600, "claude", 500, 50},
		{"kiro", 800, "kiro", 700, 70},
		{"fallback to caller", 400, "kiro", 400, 40},
	}
	for _, c := range cases {
		pid, start, found := fs.FindAgent(c.from, c.agent)
		if wantFound := c.name != "fallback to caller"; found != wantFound {
			t.Errorf("%s: found=%v, want %v", c.name, found, wantFound)
		}
		if pid != c.pid || start != c.startTime {
			t.Errorf("%s: got %d/%d, want %d/%d", c.name, pid, start, c.pid, c.startTime)
		}
	}
}

func TestFindAgentMissingProcess(t *testing.T) {
	pid, start, found := fakeTree(t).FindAgent(4242, "claude")
	if pid != 4242 || start != 0 || found {
		t.Fatalf("got %d/%d", pid, start)
	}
}

func TestAlive(t *testing.T) {
	fs := fakeTree(t)
	if !fs.Alive(300, 30) {
		t.Error("running process with matching start time must be alive")
	}
	if !fs.Alive(300, 0) {
		t.Error("unknown start time must only check existence")
	}
	if fs.Alive(300, 31) {
		t.Error("start time mismatch means the PID was reused")
	}
	if fs.Alive(4242, 0) {
		t.Error("missing process must not be alive")
	}
	if err := os.WriteFile(filepath.Join(fs.Root, "300", "stat"),
		[]byte("300 (claude) Z 200 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 30 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if fs.Alive(300, 30) {
		t.Error("zombie must not be alive")
	}
}

func TestCwd(t *testing.T) {
	fs := fakeTree(t)
	if err := WriteFakeCwd(fs.Root, 300, "/home/u/proj"); err != nil {
		t.Fatal(err)
	}
	got, err := fs.Cwd(300)
	if err != nil || got != "/home/u/proj" {
		t.Fatalf("Cwd = %q, %v", got, err)
	}
	if _, err := fs.Cwd(200); err == nil {
		t.Error("process without cwd link must error")
	}
}
