APP := build/MuDo.app
SIGN_KEYCHAIN := $(HOME)/Library/Keychains/mudo-signing.keychain-db
SIGN_PASS := $(HOME)/.mudo-signing-pass
# Signing identity, first match wins (override with SIGN_ID=...):
#  1. a valid "Apple Development" identity in the default keychains: it carries a Team ID, so
#     the Keychain remembers "Always Allow" across rebuilds (a self-signed identity has none,
#     and macOS asks again for every new build). Signed from a terminal on the Mac: over SSH
#     the login keychain is locked and codesign fails with errSecInternalComponent.
#  2. "MuDo Dev" from scripts/make-signing-identity (no -v: the self-signed cert is untrusted,
#     which codesign accepts).
#  3. ad-hoc ("-").
ifndef SIGN_ID
APPLE_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
ifneq ($(APPLE_ID),)
SIGN_ID := $(APPLE_ID)
SIGN_KEYCHAIN :=
SIGN_PASS :=
else
SIGN_ID := $(shell security find-identity -p codesigning $(wildcard $(SIGN_KEYCHAIN)) 2>/dev/null | grep -q '"MuDo Dev"' && echo "MuDo Dev" || echo -)
endif
endif

.PHONY: test build app run install clean

test:
	swift test

build:
	swift build -c release --product MuDo

app: build
	@test -f Resources/mudod || { echo "Resources/mudod missing: run 'make -C server app-resource' on the Linux side first"; exit 1; }
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/MuDo" $(APP)/Contents/MacOS/MuDo
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/mudod $(APP)/Contents/Resources/mudod
	cp Resources/AppIcon.icns Resources/StatusIcon.png Resources/StatusIcon@2x.png $(APP)/Contents/Resources/
	chmod 755 $(APP)/Contents/Resources/mudod
	@if [ -f "$(SIGN_KEYCHAIN)" ] && [ -f "$(SIGN_PASS)" ]; then \
		security unlock-keychain -p "$$(cat "$(SIGN_PASS)")" "$(SIGN_KEYCHAIN)"; fi
	codesign --force --options runtime --sign "$(SIGN_ID)" $(if $(and $(SIGN_KEYCHAIN),$(filter-out -,$(SIGN_ID))),--keychain "$(SIGN_KEYCHAIN)") $(APP)/Contents/Resources/mudod
	codesign --force --sign "$(SIGN_ID)" $(if $(and $(SIGN_KEYCHAIN),$(filter-out -,$(SIGN_ID))),--keychain "$(SIGN_KEYCHAIN)") $(APP)

run: app
	open $(APP)

install: app
	-osascript -e 'quit app "MuDo"'
	rm -rf /Applications/MuDo.app
	cp -R $(APP) /Applications/MuDo.app
	open /Applications/MuDo.app

clean:
	rm -rf .build build
