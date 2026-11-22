VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: build test app run install-app

build:
	swift build --package-path macos

test:
	swift test --package-path macos

app:
	VERSION=$(VERSION) packaging/build-app.sh

# SwiftUI needs the bundle (Info.plist, LSUIElement), so run the built app rather than the bare binary.
run: app
	open dist/MinorDLNA.app

# Copies the app to ~/Applications (Finder, Spotlight, Launchpad).
install-app: app
	mkdir -p ~/Applications
	if [ -d ~/Applications/MinorDLNA.app ]; then rm -r ~/Applications/MinorDLNA.app; fi
	cp -R dist/MinorDLNA.app ~/Applications/
