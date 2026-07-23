
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

.test-image.stamp: hack/Dockerfile.sshd-ubuntu-26.04
	@$(foreach arch,$(PLATFORMS), \
		$(DOCKER) build \
			--tag sshd-ubuntu-26.04-$(arch) \
			--file $< \
			--platform linux/$(arch) . ; )
	@touch $@

.PHONY: build-test-image
build-test-image: .test-image.stamp  ## Build test image if Dockerfile changed

.PHONY: build
build: bonsai_1.7.rock  ## Fetch model, pack the rock, inject model layers

.PHONY: model
model:  ## Download the bonsai gguf into .cache/ (idempotent)
	hack/download-model.sh

.PHONY: FORCE
FORCE:

# repack whenever any build input (rockcraft.yaml, go sources, inject
# scripts) changes -- hash_inputs.sh folds them all into one digest.
.rock.stamp: FORCE
	@new=$$(hack/hash_inputs.sh) ; \
		cur=$$(cat $@ 2>/dev/null || true) ; \
		[ "$$new" = "$$cur" ] || echo "$$new" > $@

# fetch+split first, so a model problem fails in seconds rather than after a
# multi-minute pack. inject.sh then does skopeo convert -> inject -> repack.
# CI runs the same two scripts, only packing via the craft-actions action.
bonsai_1.7.rock: .rock.stamp
	hack/split-model.sh >/dev/null
	rockcraft pack
	@base=$$(ls -t bonsai_1.7_*.rock | head -1) ; \
		echo "packed: $$base" ; \
		hack/inject.sh "$$base" $@ ; \
		rm -f "$$base"

# Default `make test` to the native arch only; override w/ SPREAD_FILTER=...
# (e.g. SPREAD_FILTER= make test  to run every system).
SPREAD_FILTER ?= craft-adhoc:ubuntu-26.04-$(NATIVE_ARCH)

test: bonsai_1.7.rock .test-image.stamp  ## Run tests (native arch; override SPREAD_FILTER=)
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
	rm -f .test-image.stamp

.PHONY: clean
clean:  ## Remove built artifacts (keeps the .cache/ model download)
	rm -f bonsai_1.7*.rock bonsai-1.7B.oci .rock.stamp .test-image.stamp
	rm -rf build/oci
