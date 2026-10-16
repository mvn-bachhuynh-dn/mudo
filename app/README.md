# MuDo (Mac app)

Floating widget that shows Claude Code and Kiro CLI sessions from `mudod` servers.

## Build

Needs macOS 26 and Xcode 26 (or its command line tools).

```bash
make test      # MuDoCore unit tests
make app       # build/MuDo.app, signed with "MuDo Dev" if present, else ad-hoc
make install   # copy to /Applications and launch
```

### Stable signing identity (one time)

Run once on the build Mac:

```bash
scripts/make-signing-identity
```

It creates a self-signed code-signing identity "MuDo Dev" in a dedicated keychain `~/Library/Keychains/mudo-signing.keychain-db` (password in `~/.mudo-signing-pass`, mode 600) and adds that keychain to the search list. It is idempotent. `make app` then signs with it (override with `make app SIGN_ID=-`), so every build has the same designated requirement (`certificate leaf = H"..."` instead of a cdhash).

After the first launch with the new signature, click "Always Allow" once on the Keychain prompt for `dev.steve.MuDo`, and allow Automation of Google Chrome once. Later rebuilds keep both and no longer prompt.

From the Linux server, `scripts/on-mac '<command>'` syncs `app/` to the Mac set in `MUDO_MAC=user@host` and runs the command there.

## Add a server

Run `mudod install` on the server, then open the printed `mudo://add?...` link on the Mac (or paste it in Settings). Append `&code_server=<url-encoded code-server URL>` to the link, or fill "code-server URL" in Settings, so that clicking a session can focus its Chrome window.

The devbox daemon is reachable on the LAN at `http://192.168.1.10:7879` (Tailscale egress from that server is blocked by Cloudflare WARP).

## Permissions

- First click on a session asks for Automation access to Google Chrome. If denied, MuDo opens a new Chrome window instead, and the menu shows "Allow MuDo to control Chrome…".
- Tokens are stored in the Keychain and read once per server per launch (then cached in memory).
- With an ad-hoc signature (no "MuDo Dev" identity), each rebuild changes the signature, so macOS asks again for Keychain access and for Automation access to Google Chrome. Run `scripts/make-signing-identity` once to stop that.
- The `mudo://add?...` link printed by `mudod install` has no `code_server`, so clicking a session would have no Chrome window to focus (MuDo opens Settings instead). Append `&code_server=<url-encoded URL>` to the link before opening it; for devbox: `&code_server=https%3A%2F%2Fcode.example.com`.
