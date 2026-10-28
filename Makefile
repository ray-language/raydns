# raydns — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt run interop bench clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./raydns
	rm -f raydns
	ray build --native --release -o raydns src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

run: build ## Serve with ./raydns.toml (copy raydns.example.toml first)
	./raydns serve

interop: build ## dig against a fresh raydns: every answer form, truncation, TCP, leases
	scripts/interop.sh

bench: build ## Queries/s and latency by number of UDP receivers (CLIENTS=N, N=queries)
	scripts/bench.sh

clean: ## Remove the binary
	rm -f raydns
