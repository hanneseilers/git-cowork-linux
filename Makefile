PREFIX ?= /Applications
APP = dist/git-cowork.app

.PHONY: app install update uninstall run test version release clean

app:            ## Build dist/git-cowork.app
	@Scripts/build-app.sh

install: app    ## Build and copy to /Applications (override with PREFIX=~/Applications)
	@rm -rf "$(PREFIX)/git-cowork.app"
	@cp -R $(APP) "$(PREFIX)/"
	@echo "✓ Installed git-cowork $$(Scripts/version.sh) to $(PREFIX)/git-cowork.app"

update:         ## Get the latest version (or newest release tag) and reinstall
	@Scripts/update.sh
	@$(MAKE) --no-print-directory install PREFIX="$(PREFIX)"

uninstall:      ## Remove the app (settings stay, see INSTALL.md)
	@rm -rf "$(PREFIX)/git-cowork.app"
	@echo "✓ Removed $(PREFIX)/git-cowork.app"

run:            ## Run a debug build from the terminal
	swift run GitCowork

test:           ## Run unit tests
	swift test

version:        ## Print the version and the commit it's built from
	@echo "$$(Scripts/version.sh) ($$(git describe --tags --always --dirty))"

release:        ## Tag a release: make release VERSION=x.y.z
	@Scripts/release.sh "$(VERSION)"

clean:
	rm -rf .build dist
