package install

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
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
	GOOS       string // empty means runtime.GOOS
	UID        int    // used for the launchctl gui/<uid> domain on macOS
	Sleep      func(time.Duration)
}

func (o Options) goos() string {
	if o.GOOS == "" {
		return runtime.GOOS
	}
	return o.GOOS
}

func (o Options) sleep(d time.Duration) {
	if o.Sleep == nil {
		time.Sleep(d)
		return
	}
	o.Sleep(d)
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
	darwin := o.goos() == "darwin"
	cfg, err := ensureConfig(o, darwin, p.Config, &res)
	if err != nil {
		return res, err
	}
	if darwin {
		if err := writeFile(p.LaunchAgent, []byte(LaunchAgentPlist(p.Bin, p.LaunchLog)), 0o644); err != nil {
			return res, fmt.Errorf("write launch agent: %w", err)
		}
		if err := bootstrapLaunchAgent(o, p.LaunchAgent); err != nil {
			return res, err
		}
	} else if err := startSystemdUnit(o, p.Unit, p.Bin, &res); err != nil {
		return res, err
	}
	if _, err := MergeClaudeSettings(p.ClaudeSettings, p.Bin+" hook --agent claude", o.Now()); err != nil {
		return res, fmt.Errorf("claude hooks: %w", err)
	}
	if err := writeFile(p.KiroHooks, KiroHooks(p.Bin+" hook --agent kiro"), 0o644); err != nil {
		return res, fmt.Errorf("kiro hooks: %w", err)
	}

	name, hostPort := cfg.Host, ""
	if darwin {
		// The app on this Mac talks to its own daemon over loopback.
		name, hostPort = "This Mac", localHostPort(cfg.APIAddr, &res)
	} else {
		hostPort = linkHostPort(o, cfg.APIAddr)
	}
	q := url.Values{"name": {name}, "url": {"http://" + hostPort}, "token": {cfg.Token}}
	if o.CodeServer != "" {
		q.Set("code_server", o.CodeServer)
	}
	res.ConnectURL = "mudo://add?" + q.Encode()
	return res, nil
}

func startSystemdUnit(o Options, unit, bin string, res *Result) error {
	if err := writeFile(unit, []byte(SystemdUnit(bin)), 0o644); err != nil {
		return fmt.Errorf("write unit: %w", err)
	}
	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", "mudod.service"},
		{"--user", "restart", "mudod.service"},
	} {
		if out, err := o.Exec("systemctl", args...); err != nil {
			return fmt.Errorf("systemctl %s: %v: %s", strings.Join(args, " "), err, out)
		}
	}
	if out, err := o.Exec("loginctl", "show-user", o.User, "--property=Linger"); err == nil && strings.TrimSpace(out) == "Linger=no" {
		res.Warnings = append(res.Warnings,
			"lingering is off, so mudod stops when you log out; run: sudo loginctl enable-linger "+o.User)
	}
	return nil
}

// Uninstall removes the unit (or LaunchAgent) and MuDo's hooks. Config, state and binary are kept.
func Uninstall(o Options) error {
	p := paths.For(o.Home)
	if o.goos() == "darwin" {
		_, _ = o.Exec("launchctl", "bootout", fmt.Sprintf("gui/%d/%s", o.UID, launchLabel))
		if err := os.Remove(p.LaunchAgent); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	} else {
		_, _ = o.Exec("systemctl", "--user", "disable", "--now", "mudod.service")
		if err := os.Remove(p.Unit); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		_, _ = o.Exec("systemctl", "--user", "daemon-reload")
	}
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

// ensureConfig loads the config or creates it with a new token. On macOS the
// API defaults to loopback, since the only client is the app on the same Mac.
func ensureConfig(o Options, darwin bool, path string, res *Result) (config.Config, error) {
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
	if !darwin {
		if out, err := o.Exec("tailscale", "ip", "-4"); err == nil && len(strings.Fields(out)) > 0 {
			ip = strings.Fields(out)[0]
		} else {
			res.Warnings = append(res.Warnings,
				"`tailscale ip -4` failed, so the API listens on 127.0.0.1 only; set api_addr in "+path)
		}
	}
	cfg = config.Config{Token: token, Host: o.Hostname, IngestAddr: config.DefaultIngestAddr, APIAddr: ip + ":" + config.DefaultAPIPort}
	return cfg, cfg.Write(path)
}

// localHostPort is the loopback address of api_addr for the app on this Mac,
// warning when the API also listens beyond loopback.
func localHostPort(apiAddr string, res *Result) string {
	host, port, err := net.SplitHostPort(apiAddr)
	if err != nil {
		port = config.DefaultAPIPort
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		res.Warnings = append(res.Warnings,
			"api_addr "+apiAddr+" is not loopback, so the API is reachable from other machines; set api_addr = \"127.0.0.1:"+port+"\" if only this Mac uses it")
	}
	return net.JoinHostPort("127.0.0.1", port)
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
