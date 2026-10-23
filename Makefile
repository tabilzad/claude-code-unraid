# Claude Code for Unraid: developer entry points.
#
# Run `./scripts/dev-env make check` to execute everything inside the pinned
# Docker image, or plain `make check` on a machine that already has shellcheck,
# shfmt, bats, php and xmllint installed. CI runs the Docker form.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PLUGIN      := claude-code-unraid
PLUGIN_DIR  := src/usr/local/emhttp/plugins/$(PLUGIN)
SH_FILES    := $(shell ./scripts/list-shell-files)
PHP_FILES   := $(shell find src scripts tests -name '*.php' -not -path 'tests/vendor/*' | sort)
PLG_TEMPLATE := plugin/$(PLUGIN).plg.in

.PHONY: check lint test build fmt lint-shell lint-php lint-plg lint-workflows test-bats test-php list-shell-files

check: lint test
	@echo "check: ok"

lint: lint-shell lint-php lint-plg lint-workflows
	@echo "lint: ok"

lint-shell:
	@echo "shellcheck ($(words $(SH_FILES)) files)"
	@shellcheck --version | sed -n 's/^version: /  shellcheck /p'
	shellcheck -x $(SH_FILES)
	@echo "shfmt -i 2 -ci -d"
	shfmt -i 2 -ci -d $(SH_FILES)

lint-php:
	@echo "php -l ($(words $(PHP_FILES)) files)"
	@for f in $(PHP_FILES); do php -l "$$f" > /dev/null || exit 1; done

# The template appears in phase 03; until then there is nothing to lint.
lint-plg:
	@if [ -f "$(PLG_TEMPLATE)" ]; then ./scripts/lint-plg "$(PLG_TEMPLATE)"; else echo "lint-plg: no template yet, skipped"; fi

lint-workflows:
	@if command -v actionlint > /dev/null 2>&1; then echo "actionlint"; actionlint; else echo "lint-workflows: actionlint not installed, skipped"; fi

test: test-bats test-php
	@echo "test: ok"

test-bats:
	bats --print-output-on-failure --recursive tests/bats

test-php:
	php tests/php/run.php

build:
	@echo "build: implemented in phase 03"

fmt:
	shfmt -i 2 -ci -w $(SH_FILES)

list-shell-files:
	@printf '%s\n' $(SH_FILES)
