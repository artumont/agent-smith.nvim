# agent-smith.nvim — developer tasks.
#
# Run `make` with no target to list everything.

NVIM ?= nvim
PATTERN ?=
FILE ?=

.DEFAULT_GOAL := help

.PHONY: help test run

help: ## List available targets
	@printf 'agent-smith.nvim\n\nTargets:\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
	@printf '\nVariables:\n'
	@printf '  %-8s %s\n' 'PATTERN' 'filter spec files by path: make test PATTERN=config'
	@printf '  %-8s %s\n' 'FILE' 'file(s) to open: make run FILE=lua/agent-smith/init.lua'
	@printf '  %-8s %s\n' 'NVIM' 'neovim binary: make test NVIM=/usr/bin/nvim'
	@printf '\n'

test: ## Run the headless test suite
	$(NVIM) --headless -l test/run.lua "$(PATTERN)"

run: ## Start Neovim with the plugin loaded, using a clean config
	$(NVIM) -u dev/init.lua $(FILE)
