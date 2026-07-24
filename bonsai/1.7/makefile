
.DEFAULT_GOAL := help

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'


DOCKER ?= docker

# Native arch for `make test` -- map uname output to docker/spread arch.
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
  NATIVE_ARCH := amd64
else ifeq ($(UNAME_M),aarch64)
  NATIVE_ARCH := arm64
else ifeq ($(UNAME_M),arm64)    # macos reports arm64, linux reports aarch64
  NATIVE_ARCH := arm64
else
  $(error unsupported host arch: $(UNAME_M))
endif

# Default to native arch only -- override w/ PLATFORMS="amd64 arm64" for both.
PLATFORMS ?= $(NATIVE_ARCH)

.PHONY: build-test-image
build-test-image:  ## Build the spread sshd test image (docker caches unchanged builds)
	@$(foreach arch,$(PLATFORMS), \
		$(DOCKER) build \
			--tag sshd-ubuntu-26.04-$(arch) \
			--file hack/Dockerfile.sshd-ubuntu-26.04 \
			--platform linux/$(arch) . ; )

.PHONY: build
build: bonsai_1.7.rock  ## Fetch+split model, pack the rock, inject model layers

.PHONY: model
model:  ## Download the bonsai gguf + licence into .cache/ (idempotent)
	hack/download-model.rb

# rockcraft pack (no model) then inject.rb does fetch+split+inject. make's own
# mtime tracking repacks when any of these inputs change -- no stamp needed.
# CI runs inject.rb the same way, only packing via the craft-actions action.
bonsai_1.7.rock: rockcraft.yaml hack/inject.rb hack/download-model.rb
	rockcraft pack
	@base=$$(ls -t bonsai_1.7_*.rock | head -1) ; \
		echo "packed: $$base" ; \
		hack/inject.rb "$$base" $@ ; \
		rm -f "$$base"

# Default `make test` to the native arch only; override w/ SPREAD_FILTER=...
# (e.g. SPREAD_FILTER= make test  to run every system).
SPREAD_FILTER ?= craft-adhoc:ubuntu-26.04-$(NATIVE_ARCH)

.PHONY: test
test: bonsai_1.7.rock build-test-image  ## Run tests (native arch; override SPREAD_FILTER=)
	spread $(SPREAD_FILTER)

.PHONY: size
size:  ## Show size of bonsai_1.7.rock if present
	@if [ -f bonsai_1.7.rock ]; then \
		du -h bonsai_1.7.rock | cut -f1; \
	else \
		echo "bonsai_1.7.rock not built"; \
	fi

.PHONY: ls-rock
ls-rock: bonsai_1.7.rock  ## List the rock filesystem (skopeo -> docker export -> tar tv)
	@tag=bonsai-ls-rock-$$$$ ; \
		skopeo --insecure-policy copy oci-archive:bonsai_1.7.rock \
		    docker-daemon:$$tag:latest > /dev/null ; \
		cid=$$($(DOCKER) create $$tag:latest) ; \
		$(DOCKER) export $$cid | tar tv ; \
		$(DOCKER) rm $$cid > /dev/null ; \
		$(DOCKER) rmi $$tag:latest > /dev/null

.PHONY: clean-test-image
clean-test-image:  ## Remove sshd-ubuntu-26.04 test images
	@$(foreach arch,$(PLATFORMS), \
		$(DOCKER) rmi -f sshd-ubuntu-26.04-$(arch) || true ; )

.PHONY: clean
clean:  ## Remove built artifacts (keeps the .cache/ model download)
	rm -f bonsai_1.7*.rock
	rm -rf build/oci
