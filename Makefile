# `make app` is the one command that turns project.yml into a launchable LowTalker.app.
SHELL := /bin/bash
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/LowTalker.app

.PHONY: app run test check-docs cli helper clean signing-identity

# Regeneration is unconditional: xcodegen is idempotent and sub-second, and a
# timestamp rule cannot see removed sources or in-place rewrites of the project.
app:
	xcodegen generate
	xcodebuild -project LowTalker.xcodeproj -scheme LowTalker -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) build
	@echo "$(APP)"

run: app
	open "$(APP)"

# The build comes first because everything after it needs the CLI: `check-docs` reads
# the driver constants out of it, and scripts/virtual-hid-driver now takes every reading
# of the machine through it.
test:
	swift build
	$(MAKE) check-docs
	scripts/virtual-hid-driver-test
	swift test

# [LAW:one-source-of-truth] `lowtalker driver pins` is the source for everything about
# the driver extension's identity: the bundle id, the team, the IORegistry node, the
# receipt ids, the two payload trees, and the verdict vocabulary. Two readers keep
# copies - scripts/virtual-hid-driver, because it is the file that deletes those paths
# and a path arriving from a subprocess is not what `sudo rm -rf` should be handed, and
# README.md, because a reader follows the runbook by hand. This is what proves the
# copies still agree.
#
# Needs `swift build` first; the `test` target runs it before this.
check-docs:
	@set -euo pipefail; \
	pins=$$(.build/debug/lowtalker driver pins) \
	  || { echo "check-docs: could not read 'lowtalker driver pins' - run 'swift build' first" >&2; exit 1; }; \
	pin() { awk -F'\t' -v k="$$1" '$$1==k{print $$2}' <<<"$$pins"; }; \
	for pair in bundle-id:BUNDLE_ID team-id:TEAM_ID elements-receipt:ELEMENTS_RECEIPT manager-app:MANAGER_APP support-dir:SUPPORT_DIR; do \
	  key=$${pair%%:*}; constant=$${pair#*:}; \
	  value=$$(pin "$$key"); \
	  [ -n "$$value" ] || { echo "check-docs: 'lowtalker driver pins' emits no $$key" >&2; exit 1; }; \
	  copy=$$(sed -n "s/^$$constant=//p" scripts/virtual-hid-driver | tr -d '"'); \
	  [ "$$copy" = "$$value" ] \
	    || { echo "check-docs: scripts/virtual-hid-driver sets $$constant=$$copy, but the CLI pins $$key=$$value" >&2; exit 1; }; \
	  echo "check-docs: scripts/virtual-hid-driver agrees with $$key"; \
	done
# What README.md quotes for a reader following the runbook by hand. The driver's identity
# comes from the CLI; the package the script fetches is the script's own pin, and stays
# there because nothing in Swift downloads anything.
	@set -euo pipefail; \
	pins=$$(.build/debug/lowtalker driver pins); \
	for key in bundle-id team-id io-node elements-receipt; do \
	  value=$$(awk -F'\t' -v k="$$key" '$$1==k{print $$2}' <<<"$$pins"); \
	  [ -n "$$value" ] || { echo "check-docs: 'lowtalker driver pins' emits no $$key" >&2; exit 1; }; \
	  grep -qF "$$value" README.md \
	    || { echo "check-docs: the CLI pins $$key=$$value, which README.md never mentions" >&2; exit 1; }; \
	  echo "check-docs: README.md agrees with $$key=$$value"; \
	done; \
	for constant in PKG_VERSION DEXT_VERSION; do \
	  pinned=$$(sed -n "s/^$$constant=//p" scripts/virtual-hid-driver); \
	  [ -n "$$pinned" ] || { echo "check-docs: scripts/virtual-hid-driver defines no $$constant" >&2; exit 1; }; \
	  grep -qF "$$pinned" README.md \
	    || { echo "check-docs: scripts/virtual-hid-driver pins $$constant=$$pinned, which README.md never mentions" >&2; exit 1; }; \
	  echo "check-docs: README.md agrees with $$constant=$$pinned"; \
	done
# The verdict vocabulary is the other copy README.md keeps: `DriverState` emits the words
# and the prose lists them. Compared as sets in both directions, so a verdict added to the
# enum and a verdict left standing in README after the enum dropped it both fail. Empty on
# either side is a broken reader, not agreement, and says so.
	@set -euo pipefail; \
	emitted=$$(.build/debug/lowtalker driver pins \
	  | awk -F'\t' '$$1=="verdicts"{print $$2}' | tr ' ' '\n' | sort -u); \
	quoted=$$(grep -o 'The verdicts are [^.]*\.' README.md \
	  | grep -o '`[a-z-]*`' | tr -d '`' | sort -u); \
	[ -n "$$emitted" ] || { echo "check-docs: 'lowtalker driver pins' emits no verdicts" >&2; exit 1; }; \
	[ -n "$$quoted" ] || { echo "check-docs: README.md carries no 'The verdicts are ...' sentence" >&2; exit 1; }; \
	diff <(echo "$$emitted") <(echo "$$quoted") \
	  || { echo "check-docs: DriverState and README.md disagree about the verdicts (< enum, > README)" >&2; exit 1; }; \
	echo "check-docs: README.md names every verdict DriverState emits"

# The helper's readings are the other vocabulary README.md keeps a copy of: every case of
# `HelperStanding` has one, and the prose lists them for a reader following the runbook by
# hand. Compared as sets in both directions, so a reading added to the enum and a reading
# left standing in README after the enum dropped it both fail. Empty on either side is a
# broken reader, not agreement, and says so. There was no check here at all until a case
# added to `HelperStanding` left README quoting a reading the code had stopped printing,
# with every other check green; this is that check.
	@set -euo pipefail; \
	emitted=$$(.build/debug/lowtalker onboard readings | sort -u); \
	quoted=$$(awk '/^So the helper.s row reads one of/{f=1;next} f&&/^- `/{print;seen=1;next} f&&seen{exit}' README.md \
	  | sed -E 's/^- `([^`]*)`.*/\1/' | sort -u); \
	[ -n "$$emitted" ] || { echo "check-docs: 'lowtalker onboard readings' emits no readings" >&2; exit 1; }; \
	[ -n "$$quoted" ] || { echo "check-docs: README.md carries no list of the helper's readings" >&2; exit 1; }; \
	diff <(echo "$$emitted") <(echo "$$quoted") \
	  || { echo "check-docs: HelperStanding and README.md disagree about the helper's readings (< enum, > README)" >&2; exit 1; }; \
	echo "check-docs: README.md names every reading the helper's row can take"

# The CLI for engine work, and the keyboard helper it types through. Both are signed
# with the dev identity rather than ad hoc: the helper admits exactly the certificate
# that signed it, so the CLI has to carry the same one to press a key. The CLI's
# identifier is fixed because the Neural Engine keeps its compiled model per signing
# identifier and `swift build` links a fresh one into every binary; a plain
# `swift run` pays the minutes-long specialization after each rebuild. The helper's is
# the identifier project.yml gives the app-embedded build, so the two builds of one
# program are one code identity; who may call it is decided by the certificate, never
# by the identifier.
# [LAW:one-source-of-truth] scripts/signing-identity reads the identity name off
# project.yml; the lookup runs in the recipe (not $(shell), which discards exit status)
# so a failing tool aborts loudly.
CLI := .build/debug/lowtalker
cli:
	swift build --product lowtalker
	codesign --force --sign "$$(scripts/signing-identity)" --identifier lowtalker "$(CLI)"
	@echo "$(CLI)"

HELPER := .build/debug/lowtalker-keyboardd
helper:
	swift build --product lowtalker-keyboardd
	codesign --force --sign "$$(scripts/signing-identity)" --identifier com.lowtalker.keyboardd "$(HELPER)"
	@echo "$(HELPER)"

# Once per Mac. Until it has run, `make app`, `make cli` and `make helper` stop with
# "No certificate matching".
signing-identity:
	scripts/make-signing-identity "$$(scripts/signing-identity)"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
