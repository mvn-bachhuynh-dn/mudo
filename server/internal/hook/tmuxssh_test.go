package hook

import "testing"

func TestPickClientPID(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"highest activity", "1760000100 501\n1760000300 502\n1760000200 503\n", "502"},
		{"single", "1760000100 501", "501"},
		{"empty", "", ""},
		{"malformed lines skipped", "junk\nx 501\n1760000100\n1760000100 502 extra\n1760000050 503\n", "503"},
		{"all malformed", "abc def\n\n", ""},
	}
	for _, c := range cases {
		if got := PickClientPID(c.in); got != c.want {
			t.Errorf("%s: PickClientPID = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestSSHFromEnviron(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		want string
	}{
		{"found", []byte("HOME=/home/dev\x00SSH_CONNECTION=100.64.0.20 52000 100.64.0.10 22\x00TERM=xterm\x00"),
			"100.64.0.20 52000 100.64.0.10 22"},
		{"last entry without NUL", []byte("A=1\x00SSH_CONNECTION=1.2.3.4 5 6.7.8.9 22"), "1.2.3.4 5 6.7.8.9 22"},
		{"missing", []byte("HOME=/home/dev\x00SSH_CLIENT=x\x00"), ""},
		{"not a prefix match", []byte("XSSH_CONNECTION=1 2 3 4\x00"), ""},
		{"empty", nil, ""},
	}
	for _, c := range cases {
		if got := SSHFromEnviron(c.in); got != c.want {
			t.Errorf("%s: SSHFromEnviron = %q, want %q", c.name, got, c.want)
		}
	}
}
