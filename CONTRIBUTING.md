# Contributing to MuDo

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- For a bug, open an issue with the **Bug report** form: MuDo and `mudod` versions (Settings shows the app version; `mudod version` on the server), macOS version, and what you expected.
- For a larger change, open an issue first so we can agree on the approach.
- Security problems: do **not** open a public issue. See [SECURITY.md](SECURITY.md).

## Development setup

You need Go (see `server/go.mod`) for `mudod`, and a Mac with Xcode 26 for the app. No Go? `make -C server docker-build` builds `mudod` in a container.

```bash
make -C server test build        # go test -race, darwin build/vet, binaries in server/dist/
make -C server app-resource      # copy the darwin mudod into the app bundle resources
cd app && make test app          # swift test, then build/MuDo.app
```

UI work without real agents: `mudod fake` serves scripted sessions (see the README, Development). `app/scripts/demo` runs a separate demo copy of the app for screenshots.

Signing: release builds are signed with a self-signed "MuDo Dev" identity (repository secrets `MUDO_SIGN_P12`, base64 of a `.p12`, and `MUDO_SIGN_P12_PASS`), so macOS keeps MuDo's Automation and Accessibility grants across updates. Without the secrets the release is signed ad-hoc. Local builds use the identity from `app/scripts/make-signing-identity`, or ad-hoc.

Icons: `app/scripts/make-icons` rebuilds the menu bar icon, the app icon and the README logos from `docs/images/mudo-logo.png` (needs `uv`). Commit its outputs.

## Pull requests

- Keep each PR to one change, with tests for logic changes (`server/internal/...` in Go, `app/Sources/MuDoCore` in Swift; the `MuDo` target is AppKit glue and is kept thin).
- CI must pass: Go tests on Linux, Swift tests and an app build on macOS.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages and the PR title, e.g. `feat(app): …`, `fix(mudod): …`, `docs: …`. Releases and the changelog are generated from them: `feat` bumps the minor version, `fix` the patch version. PRs are squash-merged, so the PR title becomes the commit on `main` and the changelog line.
- Never commit real IP addresses, hostnames, tokens or emails. Use placeholders such as `100.64.0.10`, `fd7a:115c:a1e0::10`, `code.example.com`, `devbox`.

## Releases

Maintainers merge the release PR (with `--admin`: CI does not run on it) that [release-please](https://github.com/googleapis/release-please) keeps open. Merging it tags `vX.Y.Z`, publishes the GitHub release with the changelog, and CI attaches the `mudod` binaries, `MuDo-macos-arm64.zip` and `checksums.txt`.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
