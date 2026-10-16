VERSION ?= 0.1.0
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build test vet clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/mudod-linux-amd64 ./cmd/mudod

test:
	go test -race -count=1 ./...

vet:
	go vet ./...

clean:
	rm -rf dist
