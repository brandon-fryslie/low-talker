# `make app` is the one command that turns project.yml into a launchable LowTalker.app.
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/LowTalker.app

.PHONY: app run test clean

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

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
