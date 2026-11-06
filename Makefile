PREFIX ?= /Applications
APP = dist/git-cowork.app

.PHONY: app install run test clean

app:            ## Build dist/git-cowork.app
	@Scripts/build-app.sh

install: app    ## Build and copy to /Applications (override with PREFIX=~/Applications)
	@rm -rf "$(PREFIX)/git-cowork.app"
	@cp -R $(APP) "$(PREFIX)/"
	@echo "✓ Installed to $(PREFIX)/git-cowork.app"

run:            ## Run a debug build from the terminal
	swift run GitCowork

test:           ## Run unit tests
	swift test

clean:
	rm -rf .build dist
