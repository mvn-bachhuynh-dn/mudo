#!/bin/sh
# Installs mudod on a Linux server from the latest GitHub release (or MUDO_VERSION),
# then runs `mudod install` with the given arguments. Run it as the user that runs the agents:
#
#   curl -fsSL https://raw.githubusercontent.com/mvn-bachhuynh-dn/mudo/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/mvn-bachhuynh-dn/mudo/main/install.sh | sh -s -- --code-server https://code.example.com
#
# Running it again upgrades mudod and keeps the token and config.
set -eu

repo="mvn-bachhuynh-dn/mudo"
version="${MUDO_VERSION:-latest}"

fail() { echo "mudo install: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "this script is for Linux servers; on a Mac, use MuDo.app (Settings > Monitor this Mac)"
case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) fail "unsupported CPU: $(uname -m)" ;;
esac
command -v curl >/dev/null || fail "curl is required"
command -v sha256sum >/dev/null || fail "sha256sum is required"

if [ "$version" = latest ]; then
	base="https://github.com/$repo/releases/latest/download"
else
	base="https://github.com/$repo/releases/download/v${version#v}"
fi
asset="mudod-linux-$arch"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $asset ($version)..."
curl -fsSL -o "$tmp/$asset" "$base/$asset" || fail "download failed: $base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt" || fail "download failed: $base/checksums.txt"
(cd "$tmp" && grep " $asset\$" checksums.txt | sha256sum -c - >/dev/null) || fail "checksum mismatch for $asset"
chmod 755 "$tmp/$asset"

# install copies the binary to ~/.local/bin/mudod and prints the mudo://add link for the Mac.
"$tmp/$asset" install "$@"
