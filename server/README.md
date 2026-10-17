# mudod

Server-side daemon for MuDo. It receives Claude Code / Kiro CLI hook calls and streams session state to the MuDo Mac app.

Overview, full install steps and troubleshooting: see the [top-level README](../README.md).

## Build

```bash
make test build    # produces dist/mudod-linux-amd64 and dist/mudod-darwin-arm64
make app-resource  # also copies the darwin binary to ../app/Resources/mudod for the Mac app
```

`make test` runs `go test -race` and also `GOOS=darwin GOARCH=arm64 go build ./...` and `go vet ./...`, so darwin-only files are checked from Linux. On darwin, process inspection uses `sysctl` (`kern.proc.pid`, `kern.procargs2`) and `/usr/sbin/lsof` for the working directory, instead of `/proc`. The fake-`/proc` tests are Linux-only; `MUDO_MAC=user@my-mac make test-darwin-live` cross-compiles the proc tests, copies the binary to the build Mac and runs the live darwin checks there.

## Install on a server

```bash
scp dist/mudod-linux-amd64 devbox:/tmp/mudod
ssh devbox '/tmp/mudod install'
```

`install`:

- copies the binary to `~/.local/bin/mudod`
- writes `~/.config/mudo/config.toml` (token, `api_addr` = Tailscale IP:7879)
- enables the `mudod` systemd user service
- adds hooks to `~/.claude/settings.json` (backup: `settings.json.mudo-bak-*`)
- writes `~/.kiro/hooks/mudo.json`
- prints a `mudo://add?...` link; open it on the Mac to add the server. `mudod install --code-server <url>` adds the code-server URL to the link. If `api_addr` is a wildcard such as `[::]:7879`, the link uses the Tailscale IPv6 address (then IPv4)

If it warns about lingering, run the printed `sudo loginctl enable-linger <user>` so the daemon survives logout.

If `install` fails with `Failed to connect to bus`, the user has no systemd user manager (common when the shell comes from code-server run as a system service). Enable lingering, then re-run with the runtime dir set:

```bash
sudo loginctl enable-linger "$USER"
XDG_RUNTIME_DIR=/run/user/$(id -u) ~/.local/bin/mudod install
```

Kiro hooks fire only in the interactive `kiro-cli chat` TUI, not with `--no-interactive`.

Running `install` again upgrades the binary and keeps the token.

## Install on macOS

The Mac app installs the bundled binary itself (Settings → **Monitor this Mac**), by running:

```bash
MuDo.app/Contents/Resources/mudod install --link-only
```

On darwin, `install`:

- copies the binary to `~/.local/bin/mudod`
- writes `~/.config/mudo/config.toml` with `api_addr = "127.0.0.1:7879"` (no Tailscale lookup; an existing config is kept, with a warning if its `api_addr` is not loopback)
- writes the LaunchAgent `~/Library/LaunchAgents/dev.mudo.mudod.plist` (`mudod serve`, `RunAtLoad`, `KeepAlive`, log `~/Library/Logs/mudod.log`), then `launchctl bootout` + `launchctl bootstrap gui/<uid>` (bootstrap retried up to 5 times)
- adds the same Claude Code and Kiro hooks as on Linux
- prints a `mudo://add?...` link with name `This Mac` and url `http://127.0.0.1:<port>` (port from `api_addr`)

`--link-only` prints only the link on stdout (warnings go to stderr), so a caller can parse it. `uninstall` on darwin boots out the LaunchAgent, removes the plist and the hooks.

```bash
launchctl print gui/$(id -u)/dev.mudo.mudod
tail -f ~/Library/Logs/mudod.log
```

## Ingest hardening

The hook endpoint (`127.0.0.1:7878/event`) answers 403 to any request with an `Origin` header, a `Content-Type` other than `application/json`, or a `Host` that is not the ingest's own loopback address. This stops a web page in a local browser from posting fake events; `mudod hook` sends none of these. It applies on Linux and macOS.

## Terminal info

The hook records where the agent runs (`TERM_PROGRAM`, code-server, TTY, iTerm2 session id, tmux socket/pane/binary, `SSH_CONNECTION`) and the daemon stores it on the session as `terminal`, so the app can focus the right terminal tab or editor window. Inside tmux on a server, `SSH_CONNECTION` is taken from the most recently active tmux client. Missing fields never fail the hook.

## Check it works

```bash
systemctl --user status mudod
journalctl --user -u mudod -f
TOKEN=$(sed -n 's/^token = "\(.*\)"/\1/p' ~/.config/mudo/config.toml)
curl -sN -H "Authorization: Bearer $TOKEN" http://$(tailscale ip -4):7879/v1/stream
```

Start a `claude` session in code-server and send a prompt: an `upsert` with `"state":"running"` appears, then `"done"` when it finishes.

Hook errors are logged to `~/.local/state/mudo/hook.log`. Set `MUDO_HOOK_DUMP=1` in the agent's environment to log raw hook payloads.

## Fake server for UI work

```bash
mudod fake --addr 0.0.0.0:7879 --token fake-token --step 3s
```

## Uninstall

```bash
~/.local/bin/mudod uninstall
```

Removes the systemd unit and MuDo's hooks. Config, state and the binary stay. When `uninstall` removes MuDo hooks it first backs up `~/.claude/settings.json` to `settings.json.mudo-bak-*`, and install keeps that file's existing permissions.
