# `make app` is the one command that turns project.yml into a launchable LowTalker.app.
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/LowTalker.app

# [LAW:one-source-of-truth] project.yml owns the signing identity; read it from there
# rather than spelling the name a second time. Lazy so only the target that needs it
# pays for the lookup.
SIGNING_IDENTITY = $(shell xcodegen dump --type json | jq -r '.targets.LowTalker.settings.base.CODE_SIGN_IDENTITY // empty')

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
signing-identity:
	scripts/make-signing-identity "$(SIGNING_IDENTITY)"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
