# MuDo

MuDo is a small always-on-top macOS widget that shows the Claude Code and Kiro CLI sessions running on your remote Linux servers, so you never forget an agent that finished while you were doing something else. Each session is `idle`, `running`, `waiting` (for a permission prompt) or `done`. A session that finished and is left unseen for a few minutes blinks until you act on it. Clicking a session brings its code-server tab in Google Chrome to the front.

```
Linux server (each one)                                   Mac
┌──────────────────────────────────────────┐
│ claude / kiro-cli                         │
│   └─ hook: mudod hook --agent claude|kiro │
│        └─ POST 127.0.0.1:7878/event       │
│                   ▼                       │
│ mudod serve  (systemd --user)             │
│   - session state machine                 │
│   - PID liveness check every 10 s         │
│   - ~/.local/state/mudo/state.json        │     ┌─────────────────────┐
│   - API on api_addr :7879 (bearer token) ─┼SSE─▶│ MuDo.app (SwiftUI)  │
└──────────────────────────────────────────┘     │ one stream / server │
                                                  └─────────────────────┘
```

- `server/`: `mudod`, a single static Go binary (linux/amd64): agent hooks, daemon, installer.
- `app/`: `MuDo.app`, a SwiftUI macOS app with no third-party dependencies.
- Design spec: [docs/superpowers/specs/2026-10-14-mudo-design.md](docs/superpowers/specs/2026-10-14-mudo-design.md).

## Requirements

**Server**

- Linux amd64 with a systemd user session (lingering enabled so the daemon survives logout).
- Claude Code and/or `kiro-cli`.
- Optional: code-server opened in Google Chrome, one window per project, so clicking a session can focus it.

**Mac**

- macOS 26 or later.
- Xcode 26 (or its command line tools) to build the app.
- Google Chrome (for focusing code-server tabs).

**Network**: the Mac must reach the server on TCP 7879, over Tailscale or the LAN. Traffic is plain HTTP with a bearer token; use Tailscale or a trusted LAN.

## Install: server

1. Build the binary (on any machine with Go) and copy it to the server:

   ```bash
   cd server && make test build          # -> dist/mudod-linux-amd64
   scp dist/mudod-linux-amd64 myserver:/tmp/mudod
   ```

2. Run the installer on the server as the user that runs the agents:

   ```bash
   /tmp/mudod install --code-server https://code.example.com
   ```

   `--code-server` is optional; when given, the code-server URL is added to the printed link so the Mac app can focus Chrome tabs. `install`:

   - copies the binary to `~/.local/bin/mudod`
   - writes `~/.config/mudo/config.toml` (mode 600) with a random token and `api_addr` = `<tailscale ip -4>:7879` (`127.0.0.1:7879` with a warning if Tailscale is not available)
   - writes and starts the `mudod` systemd user service
   - merges hooks into `~/.claude/settings.json` (backup: `settings.json.mudo-bak-*`; existing hooks are kept)
   - writes `~/.kiro/hooks/mudo.json`
   - prints a `mudo://add?name=…&url=…&token=…[&code_server=…]` link for the Mac

   It is idempotent: running it again (e.g. with a newer binary) upgrades the binary and keeps the token and config.

3. If it warns that lingering is off, run the printed command so the daemon survives logout:

   ```bash
   sudo loginctl enable-linger "$USER"
   ```

   If `install` fails with `Failed to connect to bus`, the shell has no systemd user manager (common when the terminal comes from code-server running as a system service). Enable lingering as above, then:

   ```bash
   XDG_RUNTIME_DIR=/run/user/$(id -u) ~/.local/bin/mudod install
   ```

4. Make the API reachable from the Mac.
   - Listen address: `api_addr` in `~/.config/mudo/config.toml`. To listen on all interfaces (Tailscale IPv4 and IPv6, LAN), set `api_addr = "[::]:7879"` and restart: `systemctl --user restart mudod`. With a wildcard address, `mudod install` prints the link with the Tailscale IPv6 address (then IPv4, then the first LAN address).
   - Firewall, e.g. with ufw:

     ```bash
     sudo ufw allow in on tailscale0 to any port 7879 proto tcp
     sudo ufw allow in on <lan-nic> to any port 7879 proto tcp   # only if the Mac uses the LAN
     ```

5. Agents:
   - Claude Code reloads hooks on the fly; already-running sessions are picked up without a restart.
   - Kiro hooks fire only in the interactive `kiro-cli chat` TUI, not with `--no-interactive`.

Check it: `systemctl --user status mudod`, then start `claude` and send a prompt; see [server/README.md](server/README.md) for a `curl` test of the stream.

## Install: Mac app

```bash
cd app
make test                        # unit tests
scripts/make-signing-identity    # one time: stable "MuDo Dev" signing identity
make install                     # build, copy to /Applications/MuDo.app, launch
```

`scripts/make-signing-identity` creates a self-signed code-signing identity in its own keychain, so every rebuild has the same signature and macOS keeps your Keychain and Automation grants. Without it the app is signed ad-hoc and prompts again after each rebuild.

Then:

1. Open the `mudo://add?...` link printed by `mudod install` on the Mac (e.g. `open 'mudo://add?...'`), or paste it in Settings → Servers → Add. If the link has no `code_server`, fill "code-server URL" for the server in Settings and click Save.
2. First run prompts:
   - Keychain access for `dev.steve.MuDo` (the server token): click **Always Allow**.
   - Automation of Google Chrome, on the first click on a session: click **Allow**.
3. Optional: Settings → **Launch at login**.

## Usage

**The pill** (collapsed widget):

- Chips with counts: blue = running, orange = waiting, green = done. A zero count is grey.
- The pill blinks when a session is done and unseen for longer than "Blink after N min" (default 5).
- Grey "offline" when every server is disconnected; "Add a server" when none is configured.
- Hover to expand the session list; it collapses shortly after the pointer leaves. Click the pill to pin it open (click again to unpin). Drag to move it; the position is remembered.

**A session row**: state icon, project (folder name), agent (`claude`/`kiro`), time in the current state (or `idle`), server name when several servers are configured, `?` when its server is offline (data may be outdated), ⏸ on a blinking row (snooze), and the last prompt on the second line.

- Order: waiting, blinking, done, running, idle.
- **Click a row**: marks a `done` session as seen (back to `idle`) and focuses its code-server tab in Chrome. Tab matching, first hit wins: the tab whose `?folder=` is the session folder, then the tab of the closest parent folder, then a tab whose title contains the project name. With no match MuDo opens a new Chrome window on `<code-server>/?folder=<cwd>`. Without a code-server URL for that server, it opens Settings.
- **Hover a blinking row**: counts as seen and snoozes it for "Snooze for N min" (default 10); ⏸ does the same.
- Below the rows, a line per server that is `offline`, `connecting…` or `token invalid`.

**Menu bar item**: Settings…, Pause blinking (1 h) / Resume blinking, Allow MuDo to control Chrome… (shown only after Automation was denied), Quit MuDo.

**Settings**:

- Servers: name, daemon URL, code-server URL, token (stored in the Keychain); Save / Remove; paste a `mudo://add` link to add one.
- Alerts: Blink after N min, Snooze for N min.
- Hidden sessions: one folder pattern per line, `*` matches anything (including `/`), matched against the full session folder. Defaults: `*/kirocrew-workspace/_bg*`, `/tmp/*`.
- Launch at login.

## Troubleshooting

**The Mac can't connect (server shows "offline").**
Check that `mudod` is running (`systemctl --user status mudod`), that `api_addr` is an address the Mac can reach (`[::]:7879` listens everywhere), and that the firewall allows 7879 on `tailscale0`/the LAN NIC. Test from the Mac with `curl -H "Authorization: Bearer <token>" http://<addr>:7879/v1/health`. If the server runs Cloudflare WARP, it drops Tailscale IPv4 (`100.64.0.0/10`) traffic: use the server's Tailscale IPv6 address (`tailscale ip -6`, URL form `http://[fd7a:…]:7879`) with `api_addr = "[::]:7879"`, or the LAN address.

**"token invalid".**
The token in Settings does not match `token` in `~/.config/mudo/config.toml` on the server. Re-open the link from `mudod install` (re-running it keeps the token) or paste the token in Settings and Save.

**A session is missing.**
Check Settings → Hidden sessions. Kiro sessions started with `--no-interactive` fire no hooks and never appear. Check the hook log (below).

**Clicking a session opens a new Chrome window.**
No open Chrome tab matched (no code-server tab for that folder or a parent folder), or Automation was denied (menu: Allow MuDo to control Chrome…). See what the focuser did:

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "dev.steve.MuDo"'
```

To test focus without clicking (e.g. over SSH): `open 'mudo://focus?project=<name>'` (or `?session=<id>`).

**Keychain or Chrome prompts after every rebuild.**
The app is signed ad-hoc. Run `app/scripts/make-signing-identity` once, rebuild, and allow once more.

**Server-side logs.**

- Daemon: `journalctl --user -u mudod -f`
- Hook errors: `~/.local/state/mudo/hook.log`
- Raw hook payloads: set `MUDO_HOOK_DUMP=1` in the agent's environment; they are appended to `hook.log`.

## Development

```
server/   Go module for mudod (cmd/mudod, internal/...)
app/      Swift package: MuDoCore (logic, unit-tested) and MuDo (app)
docs/     design spec and implementation plans
.claude/workflows/  reusable Claude Code workflows (see below)
```

### Claude Code workflows

The repo ships [Claude Code workflows](https://code.claude.com/docs/en/workflows.md) that orchestrate subagents for the usual steps. Run them as slash commands in Claude Code:

| Command | When | What it does |
|---|---|---|
| `/mudo-spec-review docs/superpowers/specs/<file>.md` | after writing a spec, before the plan | 4 reviewers (platform feasibility, codebase fit, edge cases, security), each checked by a skeptic |
| `/mudo-task` with `{ plan, task }` | executing a plan, one task at a time | implement with TDD and commit, review spec + quality, up to 3 fix rounds |
| `/mudo-review [base]` | before merging or pushing (default base `origin/main`) | review Go, Swift, tests and public-repo safety, each finding verified by a skeptic |

```bash
cd server && make test build     # go test -race, then dist/mudod-linux-amd64
cd app && make test app          # swift test, then build/MuDo.app
```

Build the Mac app from the Linux server: `app/scripts/on-mac` rsyncs `app/` to the Mac and runs a command there.

```bash
MUDO_MAC=user@my-mac app/scripts/on-mac 'make test app'
```

UI work without real agents: run a fake server that cycles scripted sessions through every state, then add `http://<host>:7879` with token `fake-token` in Settings.

```bash
mudod fake --addr 0.0.0.0:7879 --token fake-token --step 3s
```

More detail: [server/README.md](server/README.md), [app/README.md](app/README.md).

### Uninstall

- Server: `~/.local/bin/mudod uninstall` removes the systemd unit and MuDo's hooks (config, state and binary are kept; delete `~/.config/mudo`, `~/.local/state/mudo` and `~/.local/bin/mudod` to remove everything).
- Mac: quit MuDo and delete `/Applications/MuDo.app`.
