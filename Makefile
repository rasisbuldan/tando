.PHONY: test lint install uninstall release completions portability hooks secrets package

# Thin wrappers; the scripts take more options (--help).
PREFIX ?= $(HOME)/.local

test:
	test/all.sh

lint:
	test/lint.sh

portability:
	test/portability.sh

install:
	./install.sh --prefix $(PREFIX)

uninstall:
	./uninstall.sh --prefix $(PREFIX)

release:
	scripts/release.sh

# homebrew, npm, deb or all (packaging/README.md)
package:
	scripts/package.sh $(or $(TARGET),all)

completions:
	completions/gen.sh

# the pre-commit secret scan for this clone
hooks:
	git config core.hooksPath scripts/hooks
	@echo "hooks: pre-commit runs scripts/secret-scan.sh --staged"

secrets:
	scripts/secret-scan.sh
