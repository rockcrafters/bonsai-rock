
.DEFAULT_GOAL := help

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "delegated to each version dir ($(ROCKS)); e.g. 'make build' runs 'make -C <dir> build'."
	@echo "target a single version with VERSION=1.7 (e.g. 'make VERSION=1.7 test')."


# every version dir under bonsai/ that carries a makefile
ROCKS := $(patsubst %/makefile,%,$(wildcard bonsai/*/makefile))

# restrict to one version with VERSION=<x> (dir bonsai/<x>); default: all
ifdef VERSION
  TARGETS := bonsai/$(VERSION)
else
  TARGETS := $(ROCKS)
endif

# forward these goals into each selected version dir
.PHONY: build test model build-test-image size ls-rock clean clean-test-image
build test model build-test-image size ls-rock clean clean-test-image:
	@for d in $(TARGETS); do \
		echo "==> $(MAKE) -C $$d $@"; \
		$(MAKE) -C $$d $@ || exit $$?; \
	done

.PHONY: list
list:  ## List the rock version dirs
	@for d in $(ROCKS); do echo "$$d"; done

build:            ## Build every rock (VERSION=x for one)
test:             ## Test every rock (VERSION=x for one)
model:            ## Fetch model(s) into .cache/
build-test-image: ## Build the spread sshd test image(s)
size:             ## Show built rock size(s)
ls-rock:          ## List rock filesystem(s)
clean:            ## Remove built artifacts (keeps .cache/)
clean-test-image: ## Remove the spread sshd test image(s)
