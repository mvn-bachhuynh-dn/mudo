VERSION ?= 0.1.0
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build app-resource test vet clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-linux-amd64 ./cmd/mudod
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-darwin-arm64 ./cmd/mudod

# Copies the darwin daemon into the app tree so scripts/on-mac syncs it to the build Mac.
app-resource: build
	mkdir -p ../app/Resources
	cp dist/mudod-darwin-arm64 ../app/Resources/mudod

test:
	go test -race -count=1 ./...
	GOOS=darwin GOARCH=arm64 go build ./...
	GOOS=darwin GOARCH=arm64 go vet ./...

vet:
	go vet ./...

clean:
	rm -rf dist
