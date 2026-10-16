# mudod

Server-side daemon for MuDo. It receives Claude Code / Kiro CLI hook calls and streams session state to the MuDo Mac app.

## Build

```bash
make test build    # produces dist/mudod-linux-amd64
```

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
- prints a `mudo://add?...` link; open it on the Mac to add the server

If it warns about lingering, run the printed `sudo loginctl enable-linger <user>` so the daemon survives logout.

Running `install` again upgrades the binary and keeps the token.

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
