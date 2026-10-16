# MuDo (Mac app)

Floating widget that shows Claude Code and Kiro CLI sessions from `mudod` servers.

Overview, install steps, usage and troubleshooting: see the [top-level README](../README.md).

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

Run `mudod install --code-server <url>` on the server, then open the printed `mudo://add?...` link on the Mac (or paste it in Settings). Without `--code-server`, fill "code-server URL" in Settings so that clicking a session can focus its Chrome window.

The devbox daemon is reachable on the LAN at `http://192.168.1.10:7879` (Tailscale egress from that server is blocked by Cloudflare WARP).

## Permissions

- First click on a session asks for Automation access to Google Chrome. If denied, MuDo opens a new Chrome window instead, and the menu shows "Allow MuDo to control Chrome…".
- Tokens are stored in the Keychain and read once per server per launch (then cached in memory).
- With an ad-hoc signature (no "MuDo Dev" identity), each rebuild changes the signature, so macOS asks again for Keychain access and for Automation access to Google Chrome. Run `scripts/make-signing-identity` once to stop that.
- If the server has no code-server URL (link printed without `--code-server` and the Settings field empty), clicking a session has no Chrome window to focus and MuDo opens Settings instead. For devbox: `mudod install --code-server https://code.example.com`.
