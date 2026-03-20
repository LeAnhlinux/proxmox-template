VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "none")
LDFLAGS  = -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT)

.PHONY: build build-all clean test

# Build for current platform
build:
	go build -ldflags "$(LDFLAGS)" -o bin/proxmox-agent ./cmd/agent

# Build for Linux amd64 + arm64
build-all:
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o bin/proxmox-agent-linux-amd64 ./cmd/agent
	GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o bin/proxmox-agent-linux-arm64 ./cmd/agent

# Run locally for testing
run:
	go run ./cmd/agent -port 8080

# Test provision endpoint (update URL to your git raw URL)
test-provision:
	curl -s -X POST http://localhost:8080/provision \
		-H "Content-Type: application/json" \
		-d '{"script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/examples/docker.sh"}' | jq .

# Test health
test-health:
	curl -s http://localhost:8080/health | jq .

# Test async provision
test-async:
	curl -s -X POST "http://localhost:8080/provision?async=true" \
		-H "Content-Type: application/json" \
		-d '{"script_url": "https://raw.githubusercontent.com/LeAnhlinux/proxmox-template/main/scripts/examples/docker.sh", "callback_url": "https://api.example.com/callback"}' | jq .

clean:
	rm -rf bin/

test:
	go test ./...
