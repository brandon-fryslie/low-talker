# `make app` is the one command that turns project.yml into a launchable LowTalker.app.
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/LowTalker.app

.PHONY: app run test clean

# The project is derived from project.yml and the source tree it enumerates, so a new
# file under App/ regenerates it too.
APP_SOURCES := $(shell find App -type f)

LowTalker.xcodeproj: project.yml $(APP_SOURCES)
	xcodegen generate

app: LowTalker.xcodeproj
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
