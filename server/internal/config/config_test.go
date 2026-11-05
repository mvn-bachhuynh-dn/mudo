package config

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWriteLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mudo", "config.toml")
	want := Config{Token: "abc", Host: "devbox", IngestAddr: "127.0.0.1:9", APIAddr: "100.64.0.5:7879"}
	if err := want.Write(path); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, err = %v", fi.Mode().Perm(), err)
	}
	got, err := Load(path)
	if err != nil || got != want {
		t.Fatalf("got %+v, err %v", got, err)
	}
}

func TestEndedTTLRoundTripAndDefault(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	want := Config{Token: "abc", IngestAddr: DefaultIngestAddr, APIAddr: "0.0.0.0:7879", EndedTTL: 72 * time.Hour}
	if err := want.Write(path); err != nil {
		t.Fatal(err)
	}
	if got, err := Load(path); err != nil || got != want {
		t.Fatalf("got %+v, err %v", got, err)
	}

	unset := Config{Token: "abc", IngestAddr: DefaultIngestAddr, APIAddr: "0.0.0.0:7879"}
	if err := unset.Write(path); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "ended_ttl") {
		t.Fatalf("unset ended_ttl written:\n%s", data)
	}
	if got, err := Load(path); err != nil || got.EndedTTL != 0 {
		t.Fatalf("got %+v, err %v", got, err)
	}
}

func TestWriteTightensExistingFileMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	c := Config{Token: "abc", APIAddr: "0.0.0.0:7879"}
	if err := c.Write(path); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, err = %v", fi.Mode().Perm(), err)
	}
}

func TestLoadAppliesDefaultsAndIgnoresComments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	content := "# MuDo\n\ntoken = \"abc\"\napi_addr = \"0.0.0.0:7879\"\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.IngestAddr != DefaultIngestAddr || got.Token != "abc" {
		t.Fatalf("got %+v", got)
	}
}

func TestLoadErrors(t *testing.T) {
	dir := t.TempDir()
	if _, err := Load(filepath.Join(dir, "missing")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("missing file: %v", err)
	}
	cases := map[string]string{
		"no token":    "api_addr = \"0.0.0.0:7879\"\n",
		"no api":      "token = \"abc\"\n",
		"bad quote":   "token = abc\n",
		"no equals":   "token\n",
		"unknown key": "token = \"a\"\napi_addr = \"b\"\ncolour = \"red\"\n",
		"bad ttl":     "token = \"a\"\napi_addr = \"b\"\nended_ttl = \"week\"\n",
		"zero ttl":    "token = \"a\"\napi_addr = \"b\"\nended_ttl = \"0s\"\n",
	}
	for name, content := range cases {
		path := filepath.Join(dir, strings.ReplaceAll(name, " ", "_"))
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestNewToken(t *testing.T) {
	a, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewToken()
	if len(a) != 64 || a == b {
		t.Fatalf("tokens %q %q", a, b)
	}
}
