package install

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"mudo/internal/config"
	"mudo/internal/paths"
)

type Options struct {
	Home     string
	Self     string // path of the running mudod binary
	Hostname string
	User     string
	Now      func() time.Time
	// CodeServer is an optional http(s) URL added to the link as code_server.
	CodeServer string
	Exec       func(name string, args ...string) (string, error)
}

type Result struct {
	ConnectURL string
	Warnings   []string
}

func SystemdUnit(bin string) string {
	return fmt.Sprintf(`[Unit]
Description=MuDo agent session daemon
StartLimitIntervalSec=0

[Service]
ExecStart=%s serve
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
`, bin)
}

// Run performs spec section 4.3. It is safe to run again: the token is
// kept and hooks are not duplicated.
func Run(o Options) (Result, error) {
	p := paths.For(o.Home)
	var res Result

	if o.CodeServer != "" {
		u, err := url.Parse(o.CodeServer)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return res, fmt.Errorf("invalid --code-server %q: must be an http(s) URL such as https://code.example.com", o.CodeServer)
		}
	}
	if err := installBinary(o.Self, p.Bin); err != nil {
		return res, fmt.Errorf("install binary: %w", err)
	}
	cfg, err := ensureConfig(o, p.Config, &res)
	if err != nil {
		return res, err
	}
	if err := writeFile(p.Unit, []byte(SystemdUnit(p.Bin)), 0o644); err != nil {
		return res, fmt.Errorf("write unit: %w", err)
	}
	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", "mudod.service"},
		{"--user", "restart", "mudod.service"},
	} {
		if out, err := o.Exec("systemctl", args...); err != nil {
			return res, fmt.Errorf("systemctl %s: %v: %s", strings.Join(args, " "), err, out)
		}
	}
	if out, err := o.Exec("loginctl", "show-user", o.User, "--property=Linger"); err == nil && strings.TrimSpace(out) == "Linger=no" {
		res.Warnings = append(res.Warnings,
			"lingering is off, so mudod stops when you log out; run: sudo loginctl enable-linger "+o.User)
	}
	if _, err := MergeClaudeSettings(p.ClaudeSettings, p.Bin+" hook --agent claude", o.Now()); err != nil {
		return res, fmt.Errorf("claude hooks: %w", err)
	}
	if err := writeFile(p.KiroHooks, KiroHooks(p.Bin+" hook --agent kiro"), 0o644); err != nil {
		return res, fmt.Errorf("kiro hooks: %w", err)
	}

	q := url.Values{"name": {cfg.Host}, "url": {"http://" + linkHostPort(o, cfg.APIAddr)}, "token": {cfg.Token}}
	if o.CodeServer != "" {
		q.Set("code_server", o.CodeServer)
	}
	res.ConnectURL = "mudo://add?" + q.Encode()
	return res, nil
}

// Uninstall removes the unit and MuDo's hooks. Config, state and binary are kept.
func Uninstall(o Options) error {
	p := paths.For(o.Home)
	_, _ = o.Exec("systemctl", "--user", "disable", "--now", "mudod.service")
	if err := os.Remove(p.Unit); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	_, _ = o.Exec("systemctl", "--user", "daemon-reload")
	if _, err := RemoveClaudeHooks(p.ClaudeSettings, p.Bin+" hook --agent claude", o.Now()); err != nil {
		return fmt.Errorf("claude hooks: %w", err)
	}
	if err := os.Remove(p.KiroHooks); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func installBinary(self, dst string) error {
	a, errA := filepath.Abs(self)
	b, errB := filepath.Abs(dst)
	if errA == nil && errB == nil && a == b {
		return nil
	}
	// copyFile writes a temp file and renames it, so replacing a running binary works.
	return copyFile(self, dst, 0o755)
}

func ensureConfig(o Options, path string, res *Result) (config.Config, error) {
	cfg, err := config.Load(path)
	if err == nil {
		return cfg, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return config.Config{}, err
	}
	token, err := config.NewToken()
	if err != nil {
		return config.Config{}, err
	}
	ip := "127.0.0.1"
	if out, err := o.Exec("tailscale", "ip", "-4"); err == nil && len(strings.Fields(out)) > 0 {
		ip = strings.Fields(out)[0]
	} else {
		res.Warnings = append(res.Warnings,
			"`tailscale ip -4` failed, so the API listens on 127.0.0.1 only; set api_addr in "+path)
	}
	cfg = config.Config{Token: token, Host: o.Hostname, IngestAddr: config.DefaultIngestAddr, APIAddr: ip + ":" + config.DefaultAPIPort}
	return cfg, cfg.Write(path)
}

// linkHostPort turns api_addr into something a remote client can reach.
// A wildcard host (::, 0.0.0.0, empty) is replaced by the Tailscale address,
// preferring IPv6, then IPv4, then the first global non-docker interface IP.
func linkHostPort(o Options, apiAddr string) string {
	host, port, err := net.SplitHostPort(apiAddr)
	if err != nil {
		return apiAddr
	}
	if ip := net.ParseIP(host); host != "" && (ip == nil || !ip.IsUnspecified()) {
		return net.JoinHostPort(host, port)
	}
	for _, flag := range []string{"-6", "-4"} {
		if out, err := o.Exec("tailscale", "ip", flag); err == nil {
			if f := strings.Fields(out); len(f) > 0 && net.ParseIP(f[0]) != nil {
				return net.JoinHostPort(f[0], port)
			}
		}
	}
	if ip := firstGlobalIP(); ip != "" {
		return net.JoinHostPort(ip, port)
	}
	return net.JoinHostPort(host, port)
}

func firstGlobalIP() string {
	ifs, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, ifc := range ifs {
		n := ifc.Name
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 ||
			strings.HasPrefix(n, "docker") || strings.HasPrefix(n, "br-") || strings.HasPrefix(n, "veth") {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.IsGlobalUnicast() {
				return ipn.IP.String()
			}
		}
	}
	return ""
}
