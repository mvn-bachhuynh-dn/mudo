APP := build/MuDo.app

.PHONY: test build app run install clean

test:
	swift test

build:
	swift build -c release --product MuDo

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release --show-bin-path)/MuDo" $(APP)/Contents/MacOS/MuDo
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	-osascript -e 'quit app "MuDo"'
	rm -rf /Applications/MuDo.app
	cp -R $(APP) /Applications/MuDo.app
	open /Applications/MuDo.app

clean:
	rm -rf .build build
