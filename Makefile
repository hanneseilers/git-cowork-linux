PREFIX ?= /Applications
# Where `git cowork` is linked; must be on your PATH.
BINDIR ?= $(HOME)/.local/bin
APP = dist/git-cowork.app

.PHONY: app install install-cli update uninstall run test check-translations version release clean

app:            ## Build dist/git-cowork.app
	@Scripts/build-app.sh

install: app    ## Build and copy to /Applications (override with PREFIX=~/Applications)
	@rm -rf "$(PREFIX)/git-cowork.app"
	@cp -R $(APP) "$(PREFIX)/"
	@echo "✓ Installed git-cowork $$(Scripts/version.sh) to $(PREFIX)/git-cowork.app"
	@$(MAKE) --no-print-directory install-cli PREFIX="$(PREFIX)" BINDIR="$(BINDIR)"

install-cli:    ## Link the `git cowork` tool from the installed app into BINDIR (default ~/.local/bin)
	@mkdir -p "$(BINDIR)"
	@ln -sf "$(PREFIX)/git-cowork.app/Contents/Helpers/git-cowork" "$(BINDIR)/git-cowork"
	@echo "✓ Linked $(BINDIR)/git-cowork  (try: git cowork help)"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "  $(BINDIR) isn't on your PATH yet. Add to ~/.zshrc:  export PATH=\"$(BINDIR):\$$PATH\"";; esac

update:         ## Get the latest version (or newest release tag) and reinstall
	@Scripts/update.sh
	@$(MAKE) --no-print-directory install PREFIX="$(PREFIX)"

uninstall:      ## Remove the app (settings stay, see INSTALL.md)
	@rm -rf "$(PREFIX)/git-cowork.app"
	@if [ -L "$(BINDIR)/git-cowork" ]; then unlink "$(BINDIR)/git-cowork"; fi
	@echo "✓ Removed $(PREFIX)/git-cowork.app and the $(BINDIR)/git-cowork link"

run:            ## Run a debug build from the terminal
	swift run GitCowork

test:           ## Run unit tests
	swift test

check-translations: ## List UI text without a German translation
	@python3 -I Scripts/check-translations.py

version:        ## Print the version and the commit it's built from
	@echo "$$(Scripts/version.sh) ($$(git describe --tags --always --dirty))"

release:        ## Tag a release: make release VERSION=x.y.z
	@Scripts/release.sh "$(VERSION)"

clean:
	rm -rf .build dist
