# Linux (Debian / Ubuntu) build rules, included by GNUmakefile.
PREFIX ?= $(HOME)/.local
VERSION := $(shell Scripts/linux/version.sh)
ARCH := $(shell uname -m | sed 's/amd64/x86_64/;s/arm64/aarch64/')
TREE := dist/linux/git-cowork-$(VERSION)-linux-$(ARCH)

.PHONY: app install install-cli update uninstall run test e2e deb deps version check-translations release clean sync-upstream

app:            ## Build dist/linux/git-cowork-<version>-linux-<arch> (+ .tar.gz)
	@Scripts/linux/build.sh

install: app    ## Install into PREFIX (default ~/.local; PREFIX=/usr/local needs sudo)
	@GIT_COWORK_PREFIX="$(PREFIX)" Scripts/linux/install-tree.sh "$(TREE)"

install-cli:    ## Only the `git cowork` command, into BINDIR (default PREFIX/bin)
	@swift build -c release --static-swift-stdlib --product git-cowork >/dev/null
	@mkdir -p "$(or $(BINDIR),$(PREFIX)/bin)"
	@install -m 755 "$$(swift build -c release --show-bin-path)/git-cowork" "$(or $(BINDIR),$(PREFIX)/bin)/git-cowork"
	@echo "✓ Installed $(or $(BINDIR),$(PREFIX)/bin)/git-cowork  (try: git cowork help)"

update:         ## Pull the latest version (or newest release tag) and reinstall
	@Scripts/update.sh
	@$(MAKE) --no-print-directory install PREFIX="$(PREFIX)"

uninstall:      ## Remove the app (settings in ~/.config/git-cowork-gtk.plist stay)
	@rm -f "$(PREFIX)/bin/git-cowork-gtk" "$(PREFIX)/bin/git-cowork"
	@rm -rf "$(PREFIX)/share/git-cowork"
	@rm -f "$(PREFIX)/share/applications/dev.gitcowork.GitCowork.desktop" \
	       "$(PREFIX)/share/icons/hicolor/scalable/apps/dev.gitcowork.GitCowork.svg" \
	       "$(PREFIX)/share/metainfo/dev.gitcowork.GitCowork.metainfo.xml"
	@echo "✓ Removed git-cowork from $(PREFIX)"

run:            ## Run a debug build from the terminal
	swift run git-cowork-gtk

test:           ## Unit tests (core, CoworkKit, Linux platform)
	swift test

e2e:            ## End-to-end tests: CLI, keyring, ssh askpass, GUI under Xvfb
	@Scripts/linux/e2e.sh

deb:            ## Build a .deb (Debian 13+, Ubuntu 24.04+)
	@Scripts/linux/package-deb.sh

deps:           ## Install build dependencies with apt (needs sudo); Swift itself: see docs/LINUX.md
	sudo apt-get install -y git pkg-config libgtk-4-dev libadwaita-1-dev libsecret-1-dev libcurl4-openssl-dev openssh-client

version:        ## Print the version and the commit it's built from
	@echo "$(VERSION) ($$(git describe --tags --always --dirty))"

check-translations: ## UI text of the Linux app without a German translation
	@python3 -I Scripts/linux/check-translations.py

release:        ## Tag a release (same as macOS): make release VERSION=x.y.z
	@Scripts/release.sh "$(VERSION)"

sync-upstream:  ## Merge the original macOS repository's main into this branch
	@Scripts/linux/sync-upstream.sh

clean:
	rm -rf .build dist
