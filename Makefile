# `make app` is the one command that turns project.yml into a launchable LowTalker.app.
SHELL := /bin/bash
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/LowTalker.app

.PHONY: app run test check-docs cli clean signing-identity

# Regeneration is unconditional: xcodegen is idempotent and sub-second, and a
# timestamp rule cannot see removed sources or in-place rewrites of the project.
app:
	xcodegen generate
	xcodebuild -project LowTalker.xcodeproj -scheme LowTalker -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) build
	@echo "$(APP)"

run: app
	open "$(APP)"

test: check-docs
	scripts/virtual-hid-driver-test
	swift build
	swift test

# [LAW:one-source-of-truth] scripts/virtual-hid-driver pins these values; README.md
# quotes them for a reader following the runbook by hand. The script is the source and
# the README is the copy, so this is what keeps the copy from drifting quietly the next
# time a pin moves. Every pinned constant README.md quotes belongs in the list below.
check-docs:
	@set -euo pipefail; \
	for constant in PKG_VERSION DEXT_VERSION TEAM_ID BUNDLE_ID IO_NODE ELEMENTS_RECEIPT; do \
	  pinned=$$(sed -n "s/^$$constant=//p" scripts/virtual-hid-driver); \
	  [ -n "$$pinned" ] || { echo "check-docs: scripts/virtual-hid-driver defines no $$constant" >&2; exit 1; }; \
	  grep -qF "$$pinned" README.md \
	    || { echo "check-docs: scripts/virtual-hid-driver pins $$constant=$$pinned, which README.md never mentions" >&2; exit 1; }; \
	  echo "check-docs: README.md agrees with $$constant=$$pinned"; \
	done
# The verdict vocabulary is the other copy README.md keeps: `verdict_for` emits the
# words and the prose lists them. Compared as sets in both directions, so a verdict
# added to the script and a verdict left standing in README after the script dropped
# it both fail. Empty on either side is a broken reader, not agreement, and says so.
	@set -euo pipefail; \
	emitted=$$(sed -n '/^verdict_for()/,/^}/p' scripts/virtual-hid-driver \
	  | sed -n 's/.*echo \([a-z][a-z-]*\).*/\1/p' | sort -u); \
	quoted=$$(grep -o 'The verdicts are [^.]*\.' README.md \
	  | grep -o '`[a-z-]*`' | tr -d '`' | sort -u); \
	[ -n "$$emitted" ] || { echo "check-docs: found no verdict words in verdict_for" >&2; exit 1; }; \
	[ -n "$$quoted" ] || { echo "check-docs: README.md carries no 'The verdicts are ...' sentence" >&2; exit 1; }; \
	diff <(echo "$$emitted") <(echo "$$quoted") \
	  || { echo "check-docs: verdict_for and README.md disagree about the verdicts (< script, > README)" >&2; exit 1; }; \
	echo "check-docs: README.md names every verdict verdict_for emits"

# The CLI for engine work. The Neural Engine keeps its compiled model per signing
# identifier, and `swift build` links a fresh identifier into every binary, so a
# plain `swift run` pays the minutes-long specialization after each rebuild. Signing
# the built binary with a fixed identifier keeps the cache warm across rebuilds.
CLI := .build/debug/lowtalker
cli:
	swift build --product lowtalker
	codesign --force --sign - --identifier lowtalker "$(CLI)"
	@echo "$(CLI)"

# Once per Mac. Until it has run, `make app` stops with "No certificate matching".
# [LAW:one-source-of-truth] project.yml owns the identity name; the lookup runs in the
# recipe (not $(shell), which discards exit status) so a failing tool aborts loudly.
signing-identity:
	@set -euo pipefail; \
	identity=$$(xcodegen dump --type json | jq -r '.targets.LowTalker.settings.base.CODE_SIGN_IDENTITY // error("project.yml sets no CODE_SIGN_IDENTITY for target LowTalker")'); \
	scripts/make-signing-identity "$$identity"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
