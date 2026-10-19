# Single source of truth: version.txt at the repo root, bumped by release-please.
VERSION ?= $(shell cat ../version.txt 2>/dev/null || echo dev)
GO_IMAGE ?= golang:1.22
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build docker-build app-resource test test-darwin-live vet clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-linux-amd64 ./cmd/mudod
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-linux-arm64 ./cmd/mudod
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-darwin-arm64 ./cmd/mudod

# Same as build, inside a Go container: needs only Docker, not a Go toolchain.
docker-build:
	docker run --rm -v "$(CURDIR)/..:/src" -w /src/server -u "$$(id -u):$$(id -g)" \
		-e GOCACHE=/tmp/gocache -e GOPATH=/tmp/gopath $(GO_IMAGE) make build VERSION=$(VERSION)

# Copies the darwin daemon into the app tree so scripts/on-mac syncs it to the build Mac.
app-resource: build
	mkdir -p ../app/Resources
	cp dist/mudod-darwin-arm64 ../app/Resources/mudod

test:
	go test -race -count=1 ./...
	GOOS=darwin GOARCH=arm64 go build ./...
	GOOS=darwin GOARCH=arm64 go vet ./...

# Runs the darwin-only live proc tests on the build Mac (no Go toolchain there):
# cross-compiles the test binary, copies it over and runs it. MUDO_MAC is the
# ssh destination, as for scripts/on-mac.
test-darwin-live:
	@test -n "$(MUDO_MAC)" || { echo "MUDO_MAC is not set (ssh destination of the build Mac)" >&2; exit 1; }
	mkdir -p dist
	GOOS=darwin GOARCH=arm64 go test -c -o dist/proc-darwin.test ./internal/proc
	scp dist/proc-darwin.test $(MUDO_MAC):proc-darwin.test
	ssh $(MUDO_MAC) './proc-darwin.test -test.run TestDarwinLive -test.v'

vet:
	go vet ./...

clean:
	rm -rf dist
