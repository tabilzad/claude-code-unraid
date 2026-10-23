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

lint: lint-shell lint-php lint-plg lint-workflows lint-escaping
	@echo "lint: ok"

# No .page or PHP file may print a variable into HTML without escaping it.
lint-escaping:
	./scripts/lint-escaping --allow scripts/lint-escaping.allow src tests scripts

lint-shell:
	@echo "shellcheck ($(words $(SH_FILES)) files)"
	@shellcheck --version | sed -n 's/^version: /  shellcheck /p'
	shellcheck -x $(SH_FILES)
	@echo "shfmt -i 2 -ci -d"
	shfmt -i 2 -ci -d $(SH_FILES)

PHP_SHEBANG_FILES := $(shell grep -rl --include='*' -m1 '^\#!/usr/bin/env php' src scripts 2>/dev/null | sort)
PAGE_FILES := $(shell find src -name '*.page' | sort)

lint-php:
	@echo "php -l ($(words $(PHP_FILES)) .php files, $(words $(PHP_SHEBANG_FILES)) PHP scripts, $(words $(PAGE_FILES)) pages)"
	@for f in $(PHP_FILES) $(PHP_SHEBANG_FILES); do php -l "$$f" > /dev/null || exit 1; done
	@mkdir -p .tmp/pages
	@for f in $(PAGE_FILES); do sed '1,/^---$$/d' "$$f" > ".tmp/pages/$$(basename "$$f").php" && php -l ".tmp/pages/$$(basename "$$f").php" > /dev/null || exit 1; done

# Render the template with dev values, then check it with xmllint (entity
# expansion) and our own rules.
lint-plg:
	@echo "lint-plg"
	@mkdir -p .tmp/lint
	@./scripts/render-plg --version 0000.00.00.0-dev --plugin-version 0.0.0-dev \
	  --txz-name $(PLUGIN)-0000.00.00.0_dev-noarch-1.txz \
	  --txz-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
	  --out .tmp/lint/$(PLUGIN).plg > /dev/null
	xmllint --noent --noout .tmp/lint/$(PLUGIN).plg
	./scripts/lint-plg .tmp/lint/$(PLUGIN).plg

lint-workflows:
	@if command -v actionlint > /dev/null 2>&1; then echo "actionlint"; actionlint; else echo "lint-workflows: actionlint not installed, skipped"; fi

test: test-bats test-php
	@echo "test: ok"

test-bats:
	bats --print-output-on-failure --recursive tests/bats

test-php:
	php tests/php/run.php

# make build                      -> dist/<pkg>.txz + dist/claude-code-unraid.plg (dev version)
# make build VERSION=2026.10.23.1 PLUGIN_VERSION=0.1.0 TXZ_URL=https://.../pkg.txz
VERSION        ?= 0000.00.00.0-dev
PLUGIN_VERSION ?= 0.0.0-dev
TXZ_URL        ?=
DIST           ?= dist

build:
	@txz="$$(./scripts/build-txz --version $(VERSION) --out-dir $(DIST))" && \
	  ./scripts/render-plg --version $(VERSION) --plugin-version $(PLUGIN_VERSION) \
	    --txz "$$txz" $(if $(TXZ_URL),--txz-url $(TXZ_URL),) --out $(DIST)/$(PLUGIN).plg && \
	  ./scripts/lint-plg $(DIST)/$(PLUGIN).plg && \
	  ls -la $(DIST)

# Runs Lime's real plugin manager against the rendered plg inside the dev
# container (needs root in the container: ./scripts/dev-env --root make e2e-install).
e2e-install:
	tests/e2e/plg-install.sh

fmt:
	shfmt -i 2 -ci -w $(SH_FILES)

list-shell-files:
	@printf '%s\n' $(SH_FILES)
