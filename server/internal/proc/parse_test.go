package proc

import (
	"reflect"
	"testing"
)

func TestParseLsofCwd(t *testing.T) {
	got, err := parseLsofCwd("p123\nfcwd\nn/Users/dev/My Proj\n")
	if err != nil || got != "/Users/dev/My Proj" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := parseLsofCwd("p123\n"); err == nil {
		t.Fatal("want error without n line")
	}
}

func TestParseProcargs2(t *testing.T) {
	b := []byte{2, 0, 0, 0}
	b = append(b, "/opt/homebrew/bin/claude\x00\x00\x00claude\x00--resume\x00HOME=/x\x00"...)
	exe, args, err := parseProcargs2(b)
	if err != nil || exe != "/opt/homebrew/bin/claude" || !reflect.DeepEqual(args, []string{"claude", "--resume"}) {
		t.Fatalf("got %q %q %v", exe, args, err)
	}
	if _, _, err := parseProcargs2([]byte{1, 0}); err == nil {
		t.Fatal("want error on short buffer")
	}
}

func TestStatFromKinfo(t *testing.T) {
	s := statFromKinfo("claude", 42, 1700000000, 250, 2)
	if s.Comm != "claude" || s.PPID != 42 || s.StartTime != 1700000000000250 || s.State != "R" {
		t.Fatalf("got %+v", s)
	}
	if statFromKinfo("x", 1, 0, 0, 5).State != "Z" {
		t.Fatal("SZOMB must map to Z")
	}
}
