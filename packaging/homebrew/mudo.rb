# Source of Casks/mudo.rb in https://github.com/mvn-bachhuynh-dn/homebrew-tap.
# The release workflow sets version and sha256 and pushes it there; edit the cask here.
cask "mudo" do
  version "0.2.0"
  sha256 "77fd57f9008d5da20ca8b3cc914c82aee6a301c8f267e896edfbf74b260171c5"

  url "https://github.com/mvn-bachhuynh-dn/mudo/releases/download/v#{version}/MuDo-macos-arm64.zip"
  name "MuDo"
  desc "Floating widget showing which Claude Code and Kiro sessions need you"
  homepage "https://github.com/mvn-bachhuynh-dn/mudo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "MuDo.app"

  # The app is signed ad hoc, not notarized: clear the quarantine flag so Gatekeeper
  # does not block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/MuDo.app"]
  end

  uninstall quit: "dev.steve.MuDo"

  zap trash: "~/Library/Preferences/dev.steve.MuDo.plist"

  caveats <<~EOS
    If "Monitor this Mac" is on, turn it off in MuDo Settings before uninstalling:
    it removes the mudod LaunchAgent and the agent hooks.
  EOS
end
