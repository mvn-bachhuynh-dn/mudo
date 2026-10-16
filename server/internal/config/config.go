// Package config reads and writes ~/.config/mudo/config.toml, a flat file of
// `key = "value"` lines (a strict subset of TOML).
package config

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	DefaultIngestAddr = "127.0.0.1:7878"
	DefaultAPIPort    = "7879"
)

type Config struct {
	Token      string
	Host       string
	IngestAddr string
	APIAddr    string
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("config: %w", err)
	}
	var c Config
	fields := map[string]*string{"token": &c.Token, "host": &c.Host, "ingest_addr": &c.IngestAddr, "api_addr": &c.APIAddr}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, raw, ok := strings.Cut(line, "=")
		if !ok {
			return Config{}, fmt.Errorf("config: %s:%d: expected key = \"value\"", path, n)
		}
		dst, known := fields[strings.TrimSpace(key)]
		if !known {
			return Config{}, fmt.Errorf("config: %s:%d: unknown key %q", path, n, strings.TrimSpace(key))
		}
		val, err := strconv.Unquote(strings.TrimSpace(raw))
		if err != nil {
			return Config{}, fmt.Errorf("config: %s:%d: value must be a quoted string", path, n)
		}
		*dst = val
	}
	if c.IngestAddr == "" {
		c.IngestAddr = DefaultIngestAddr
	}
	if c.Token == "" {
		return Config{}, errors.New("config: token is required")
	}
	if c.APIAddr == "" {
		return Config{}, errors.New("config: api_addr is required")
	}
	return c, nil
}

func (c Config) Write(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	content := fmt.Sprintf("# MuDo daemon config\ntoken = %q\nhost = %q\ningest_addr = %q\napi_addr = %q\n",
		c.Token, c.Host, c.IngestAddr, c.APIAddr)
	return os.WriteFile(path, []byte(content), 0o600)
}

func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
