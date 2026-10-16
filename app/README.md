# MuDo (Mac app)

Floating widget that shows Claude Code and Kiro CLI sessions from `mudod` servers.

## Build

Needs macOS 26 and Xcode 26 (or its command line tools).

```bash
make test      # MuDoCore unit tests
make app       # build/MuDo.app, ad-hoc signed
make install   # copy to /Applications and launch
```

From the Linux server, `scripts/on-mac '<command>'` syncs `app/` to the Mac set in `MUDO_MAC=user@host` and runs the command there.

## Add a server

Run `mudod install` on the server, then open the printed `mudo://add?...` link on the Mac (or paste it in Settings). Append `&code_server=<url-encoded code-server URL>` to the link, or fill "code-server URL" in Settings, so that clicking a session can focus its Chrome window.

The devbox daemon is reachable on the LAN at `http://192.168.1.10:7879` (Tailscale egress from that server is blocked by Cloudflare WARP).

## Permissions

- First click on a session asks for Automation access to Google Chrome. If denied, MuDo opens a new Chrome window instead, and the menu shows "Allow MuDo to control Chrome…".
- Tokens are stored in the Keychain. Each rebuild changes the ad-hoc signature, so macOS may ask once to allow Keychain access after an update.
