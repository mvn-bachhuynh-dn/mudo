# MuDo: notes for coding agents

MuDo = `mudod` (Go daemon + agent hooks, `server/`) and `MuDo.app` (SwiftUI macOS widget, `app/`). Read README.md for behavior and CONTRIBUTING.md for the workflow.

## Public repo: never leak private data

This repository is public. Never commit real IP addresses, hostnames, domains, tokens, emails or usernames, not even in tests, docs, screenshots or commit messages. Use the placeholders already in use: `100.64.0.10`, `fd7a:115c:a1e0::10`, `192.168.1.10`, `code.example.com`, `devbox`, `user@`. Screenshots come from `app/scripts/demo` (fake sessions), never from a real setup. Scan the diff before pushing.

## Build and test

- Go: `make -C server test` (race tests, plus darwin build and vet). Without Go: `make -C server docker-build`.
- Swift: `cd app && make test` on a Mac. Only `MuDoCore` is unit-tested; keep logic there and the `MuDo` target (AppKit glue) thin.
- From Linux, `MUDO_MAC=<ssh host> app/scripts/on-mac '<cmd>'` syncs `app/` to a Mac and runs the command there. If no Mac is reachable, `app/scripts/docker-test` runs the MuDoCore tests in a Swift container (the AppKit target is not compiled then; say so).
- The app bundles the darwin mudod: run `make -C server app-resource` before `make -C app app`.
- Darwin-only live checks: `make -C server test-darwin-live MUDO_MAC=<ssh host>`.

## Rules for code and tests

- Tests never touch the real `$HOME`, `~/.claude`, `~/.kiro`, `~/.config`, `systemctl` or `launchctl`; inject paths and runners. Do not run `mudod install`/`uninstall` against a real machine unless the user asks.
- `mudod` accepts events only on loopback ingest (`127.0.0.1:7878`) and rejects browser-style requests; the client API (`:7879`) always requires the bearer token. Keep both properties.
- The app never executes a binary path received over the network (see `TmuxPick`): only fixed, known paths.
- Match the surrounding style and comment density; new logic gets a test that fails without it.

## Commits, PRs, releases

- Conventional Commits (`feat(app):`, `fix(mudod):`, `docs:`, `ci:`, `chore:` …), one logical change per commit. release-please builds the changelog and version from them: `feat` = minor, `fix` = patch.
- Work on a branch and open a PR; do not push to `main`. CI (Go, Swift on macOS, CodeQL) must pass.
- `version.txt` is the single version source (also written to `app/Resources/Info.plist`); do not bump it by hand, release-please does.

## Claude Code workflows

`.claude/workflows/`: `/mudo-spec-review <spec>` before planning, `/mudo-task {plan, task}` per plan task, `/mudo-review [base]` before merging. Specs and plans live in `docs/superpowers/`.
