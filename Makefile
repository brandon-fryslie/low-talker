# `make app` is the one command that turns project.yml into a launchable LowTalker.app.
SHELL := /bin/bash
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/LowTalker.app

.PHONY: app run test clean signing-identity

# Regeneration is unconditional: xcodegen is idempotent and sub-second, and a
# timestamp rule cannot see removed sources or in-place rewrites of the project.
app:
	xcodegen generate
	xcodebuild -project LowTalker.xcodeproj -scheme LowTalker -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) build
	@echo "$(APP)"

run: app
	open "$(APP)"

test:
	swift build
	swift test

# Once per Mac. Until it has run, `make app` stops with "No certificate matching".
# [LAW:one-source-of-truth] project.yml owns the identity name; the lookup runs in the
# recipe (not $(shell), which discards exit status) so a failing tool aborts loudly.
signing-identity:
	@set -euo pipefail; \
	identity=$$(xcodegen dump --type json | jq -r '.targets.LowTalker.settings.base.CODE_SIGN_IDENTITY // error("project.yml sets no CODE_SIGN_IDENTITY for target LowTalker")'); \
	scripts/make-signing-identity "$$identity"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
