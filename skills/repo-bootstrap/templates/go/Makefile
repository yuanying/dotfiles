# __APP__
#
# `make test` passes with nothing but the Go toolchain and is the loop to stay
# in while developing. Tests that need more than that go behind a build tag
# of their own, so that `go test ./...` never picks them up.
#
# golangci-lint and govulncheck are declared in go.mod's tool directive and run
# through `go tool`, so every checkout runs the same version and nothing is
# installed globally.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

GO ?= go
APP ?= __APP__
BIN ?= bin/$(APP)

# The version written into the binary. The release workflow passes the tag.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS ?= -s -w -X main.version=$(VERSION)
# What `make dist` builds, as GOOS/GOARCH.
DIST_PLATFORMS ?= linux/amd64 linux/arm64 darwin/amd64 darwin/arm64

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Build

.PHONY: build
build: ## Build the binary into bin/.
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o $(BIN) ./cmd/$(APP)

.PHONY: dist
dist: ## Build the release archives and their checksums into dist/.
	rm -rf dist
	mkdir -p dist
	for platform in $(DIST_PLATFORMS); do \
		os="$${platform%/*}"; arch="$${platform#*/}"; \
		CGO_ENABLED=0 GOOS="$$os" GOARCH="$$arch" \
			$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o "dist/$(APP)" ./cmd/$(APP); \
		tar -C dist -czf "dist/$(APP)_$(VERSION)_$${os}_$${arch}.tar.gz" "$(APP)"; \
		rm "dist/$(APP)"; \
	done
	cd dist && shasum -a 256 *.tar.gz > checksums.txt

##@ Check

.PHONY: fmt
fmt: ## Format the source tree.
	$(GO) fmt ./...

.PHONY: fmt-check
fmt-check: ## Fail if any file is not gofmt'd.
	@unformatted="$$(gofmt -l . | grep -vE '^(bin|dist)/' || true)"; \
	if [ -n "$$unformatted" ]; then \
		echo "Not gofmt'd. Run \`make fmt\`:"; \
		echo "$$unformatted" | sed 's/^/  /'; \
		exit 1; \
	fi

.PHONY: vet
vet: ## Run go vet over every package.
	$(GO) vet ./...

.PHONY: lint
lint: ## Run golangci-lint.
	$(GO) tool golangci-lint run ./...

.PHONY: lint-fix
lint-fix: ## Run golangci-lint and apply the fixes it can make itself.
	$(GO) tool golangci-lint run --fix ./...

.PHONY: vuln
vuln: ## Report known vulnerabilities in the code paths the module calls.
	$(GO) tool govulncheck ./...

##@ Test

.PHONY: test
test: ## Unit tests. Need nothing but the Go toolchain.
	$(GO) test ./...

##@ Housekeeping

.PHONY: tidy
tidy: ## Tidy go.mod and go.sum.
	$(GO) mod tidy

.PHONY: clean
clean: ## Remove build artifacts.
	rm -rf bin dist
