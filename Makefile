SHELL := /bin/bash
IMAGE ?= toroute:dev
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

.PHONY: fmt vet test cross-build build privacy-scan policy-test runtime-budget-test release-tools-test repository-test validate validate-build docker-build docker-validation-images docker-inventory docker-config-test docker-live-test docker-benchmark docker-network-test docker-child-failure-test bridge-live-test clean
fmt:
	@test -z "$$(gofmt -l cmd internal tests)" || { gofmt -d cmd internal tests; exit 1; }
vet:
	go vet ./...
test:
	./scripts/test-go.sh
cross-build:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...
build:
	mkdir -p bin
	CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.buildDate=$(BUILD_DATE)" -o bin/toroute ./cmd/toroute
privacy-scan:
	./scripts/privacy-scan.sh
policy-test:
	python3 ./scripts/test-policy-tools.py
	python3 ./scripts/test-sanitize-validation-evidence.py
runtime-budget-test:
	python3 ./scripts/test-runtime-budget.py
release-tools-test:
	./scripts/test-release-tools.sh
repository-test:
	./scripts/validate-repository.sh
validate:
	python3 ./scripts/validate-source.py
validate-build: build cross-build
docker-build:
	docker build --pull --target runtime --build-arg VERSION=$(VERSION) --build-arg COMMIT=$(COMMIT) --build-arg BUILD_DATE=$(BUILD_DATE) -t $(IMAGE) .
docker-validation-images: docker-build
	docker build --target netprobe -t toroute-netprobe:ci .
	docker build --target proxycheck -t toroute-proxycheck:ci .
	docker run --rm toroute-proxycheck:ci --help >/dev/null
docker-inventory: docker-build
	./scripts/image-inventory.sh $(IMAGE) image-inventory.json
docker-config-test: docker-build
	./scripts/docker-config-test.sh $(IMAGE)
docker-live-test: docker-build
	LIVE_METRICS_OUTPUT=runtime-metrics.json ./scripts/live-smoke.sh $(IMAGE)
docker-benchmark: docker-build
	./scripts/runtime-benchmark.sh $(IMAGE) runtime-metrics.json
docker-network-test: docker-build
	docker build --target netprobe -t toroute-netprobe:ci .
	./scripts/compose-network-test.sh $(IMAGE) toroute-netprobe:ci
docker-child-failure-test: docker-build
	./scripts/docker-child-failure-test.sh $(IMAGE)
bridge-live-test: docker-build
	@test -n "$(BRIDGES_FILE)" || { echo 'set BRIDGES_FILE to an absolute path outside the repository' >&2; exit 1; }
	./scripts/bridge-live-test.sh $(IMAGE) "$(BRIDGES_FILE)"
clean:
	rm -rf bin release coverage.out image-inventory.json runtime-metrics.json scripts/__pycache__
