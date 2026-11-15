VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X github.com/novami/minor-dlna/internal/version.Version=$(VERSION)

.PHONY: build test run

build:
	go build -ldflags "$(LDFLAGS)" -o bin/minordlna ./cmd/minordlna

test:
	go vet ./... && go test ./...

run: build
	./bin/minordlna -debug
