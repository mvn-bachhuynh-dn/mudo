# Security policy

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability** on this repository ([private vulnerability reporting](https://github.com/mvn-bachhuynh-dn/mudo/security/advisories/new)). Do not open a public issue.

Include what is affected (`mudod` or the Mac app, version), how to reproduce it, and the impact. You should get a first answer within 7 days.

## Scope notes

- `mudod`'s API is plain HTTP with a bearer token, meant for Tailscale or a trusted LAN. Exposing port 7879 to the internet is not a supported setup.
- The token is stored in `~/.config/mudo/config.toml` (mode 600) on the server and in the macOS Keychain on the Mac.
- The ingest port 7878 listens on loopback only and rejects browser requests (Origin header, non-JSON content type, foreign Host).
