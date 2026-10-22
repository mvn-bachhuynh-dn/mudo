APP := build/MuDo.app
SIGN_KEYCHAIN := $(HOME)/Library/Keychains/mudo-signing.keychain-db
SIGN_PASS := $(HOME)/.mudo-signing-pass
# Stable identity from scripts/make-signing-identity when present, else ad-hoc ("-").
# No -v: the self-signed cert is untrusted, which codesign accepts.
ifndef SIGN_ID
SIGN_ID := $(shell security find-identity -p codesigning $(wildcard $(SIGN_KEYCHAIN)) 2>/dev/null | grep -q '"MuDo Dev"' && echo "MuDo Dev" || echo -)
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
	codesign --force --options runtime --sign "$(SIGN_ID)" $(if $(filter-out -,$(SIGN_ID)),--keychain "$(SIGN_KEYCHAIN)") $(APP)/Contents/Resources/mudod
	codesign --force --sign "$(SIGN_ID)" $(if $(filter-out -,$(SIGN_ID)),--keychain "$(SIGN_KEYCHAIN)") $(APP)

run: app
	open $(APP)

install: app
	-osascript -e 'quit app "MuDo"'
	rm -rf /Applications/MuDo.app
	cp -R $(APP) /Applications/MuDo.app
	open /Applications/MuDo.app

clean:
	rm -rf .build build
