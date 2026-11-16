VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/novami/minor-dlna/internal/version.Version=$(VERSION)

.PHONY: build test run app install-app

build:
	go build -ldflags "$(LDFLAGS)" -o bin/minordlna ./cmd/minordlna

test:
	go vet ./... && go test ./...

run: build
	./bin/minordlna -debug

app:
	VERSION=$(VERSION) packaging/build-app.sh

# Copies the app to ~/Applications (Finder, Spotlight, Launchpad).
install-app: app
	mkdir -p ~/Applications
	if [ -d ~/Applications/MinorDLNA.app ]; then rm -r ~/Applications/MinorDLNA.app; fi
	cp -R dist/MinorDLNA.app ~/Applications/
