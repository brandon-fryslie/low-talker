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
# of the machine through it. This is why `check-docs` is a recipe line here rather than a
# prerequisite: a prerequisite would run before `swift build`, against a stale CLI or none.
#
# Signing last is what makes a test run safe to leave behind. Every link SwiftPM performs
# ad-hoc signs the product, dropping the dev identity the helper admits callers by, so
# without this a green run leaves the next `lowtalker` refused with NSCocoaErrorDomain
# 4097 - a failure reporting success. [LAW:no-silent-failure] Unconditional, because a
# recipe cannot see what SwiftPM chose to link. [LAW:dataflow-not-control-flow]
test:
	swift build
	$(MAKE) check-docs
	scripts/virtual-hid-driver-test
	swift test
	$(MAKE) cli helper

# [LAW:one-source-of-truth] `lowtalker driver pins` is the source for everything about
# the driver extension's identity: the bundle id, the team, the IORegistry node, the
# receipt ids, the two payload trees, and the verdict vocabulary. Two readers keep
# copies - scripts/virtual-hid-driver, because it is the file that deletes those paths
# and a path arriving from a subprocess is not what `sudo rm -rf` should be handed, and
# README.md, because a reader follows the runbook by hand. This is what proves the
# copies still agree.
#
# The script's copies are read by SOURCING it rather than by grepping its assignments,
# because two of them are built out of the others - `PKG_URL` from `$PKG_VERSION`, and
# `MANAGER` from `$MANAGER_APP` - and a grep hands back the template rather than the
# value. Expanding those here would be this recipe keeping a second implementation of
# the script's own semantics, which is the drift it exists to catch; sourcing makes the
# script resolve them, which is the only resolution that cannot disagree with what the
# script actually runs. The script is written to be sourced: everything it DOES is
# behind its `BASH_SOURCE[0] == $0` guard, so this defines its constants and runs none
# of its verbs.
#
# Needs `swift build` first; the `test` target runs it before this.
check-docs:
	@set -euo pipefail; \
	pairs="bundle-id:BUNDLE_ID team-id:TEAM_ID elements-receipt:ELEMENTS_RECEIPT \
	       manager-app:MANAGER_APP manager-executable:MANAGER support-dir:SUPPORT_DIR \
	       package-version:PKG_VERSION package-url:PKG_URL"; \
	pins=$$(.build/debug/lowtalker driver pins) \
	  || { echo "check-docs: could not read 'lowtalker driver pins' - run 'swift build' first" >&2; exit 1; }; \
	copies=$$( \
	    source scripts/virtual-hid-driver; \
	    for pair in $$pairs; do name=$${pair#*:}; printf '%s\t%s\n' "$$name" "$${!name}"; done \
	  ) || { echo "check-docs: scripts/virtual-hid-driver did not resolve every constant check-docs asks it for" >&2; exit 1; }; \
	look() { awk -F'\t' -v k="$$2" '$$1==k{print $$2}' <<<"$$1"; }; \
	for pair in $$pairs; do \
	  key=$${pair%%:*}; name=$${pair#*:}; \
	  value=$$(look "$$pins" "$$key"); \
	  [ -n "$$value" ] || { echo "check-docs: 'lowtalker driver pins' emits no $$key" >&2; exit 1; }; \
	  copy=$$(look "$$copies" "$$name"); \
	  [ -n "$$copy" ] || { echo "check-docs: scripts/virtual-hid-driver leaves $$name empty" >&2; exit 1; }; \
	  [ "$$copy" = "$$value" ] \
	    || { echo "check-docs: scripts/virtual-hid-driver resolves $$name=$$copy, but the CLI pins $$key=$$value" >&2; exit 1; }; \
	  echo "check-docs: scripts/virtual-hid-driver agrees with $$key"; \
	done
# What README.md quotes for a reader following the runbook by hand. The driver's identity
# comes from the CLI, and so do the package and the Manager now: nothing in Swift downloads
# or activates anything, but onboarding has to NAME both to a reader who installed
# LowTalker.app and has no clone, for whom `scripts/virtual-hid-driver install` is not an
# instruction. The script still holds the pins it acts on, because it is the file that
# fetches the bytes and runs the Manager; the loop above is what proves the copies agree.
	@set -euo pipefail; \
	pins=$$(.build/debug/lowtalker driver pins); \
	for key in bundle-id team-id io-node elements-receipt package-url manager-executable; do \
	  value=$$(awk -F'\t' -v k="$$key" '$$1==k{print $$2}' <<<"$$pins"); \
	  [ -n "$$value" ] || { echo "check-docs: 'lowtalker driver pins' emits no $$key" >&2; exit 1; }; \
	  grep -qF "$$value" README.md \
	    || { echo "check-docs: the CLI pins $$key=$$value, which README.md never mentions" >&2; exit 1; }; \
	  echo "check-docs: README.md agrees with $$key=$$value"; \
	done; \
	for constant in PKG_VERSION DEXT_VERSION; do \
	  pinned=$$(source scripts/virtual-hid-driver; printf '%s' "$${!constant}"); \
	  [ -n "$$pinned" ] || { echo "check-docs: scripts/virtual-hid-driver leaves $$constant empty" >&2; exit 1; }; \
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

# The onboarding rows' readings are the other vocabulary README.md keeps a copy of: every
# case of `HelperStanding` has one, so does each of the assistant's two answers, and the
# prose lists them for a reader following the runbook by hand. Compared as sets in both
# directions, so a reading added to the enum and a reading left standing in README after
# the enum dropped it both fail. Empty on either side is a broken reader, not agreement,
# and says so. There was no check here at all until a case added to `HelperStanding` left
# README quoting a reading the code had stopped printing, with every other check green;
# this is that check.
#
# One loop over the rows rather than one recipe block per row, because the rows differ
# only in which lines of README hold their copy. `onboard readings` names the row on every
# line for exactly this: the assistant's two readings were hand-copied into README with
# nothing checking them, while the helper's five were proven, and the command's output
# gave no way to notice. [LAW:one-type-per-behavior]
#
# The driver extension's row is not here. Its readings are the verdict words, and the
# block above already holds README's one copy of those to `DriverState` - a second check
# of one copy is a second rulebook, not a second belt. [LAW:single-enforcer]
	@set -euo pipefail; \
	readings=$$(.build/debug/lowtalker onboard readings); \
	[ -n "$$readings" ] || { echo "check-docs: 'lowtalker onboard readings' emits no readings" >&2; exit 1; }; \
	check_row() { \
	  emitted=$$(awk -F'\t' -v row="$$1" '$$1==row{print $$2}' <<<"$$readings" | sort -u); \
	  quoted=$$(awk -v lead="$$2" '$$0 ~ lead{f=1;next} f&&/^- `/{print;seen=1;next} f&&seen{exit}' README.md \
	    | sed -E 's/^- `([^`]*)`.*/\1/' | sort -u); \
	  [ -n "$$emitted" ] || { echo "check-docs: 'lowtalker onboard readings' emits nothing for $$1" >&2; exit 1; }; \
	  [ -n "$$quoted" ] || { echo "check-docs: README.md carries no list of the readings for $$1" >&2; exit 1; }; \
	  diff <(echo "$$emitted") <(echo "$$quoted") \
	    || { echo "check-docs: the code and README.md disagree about the readings for $$1 (< code, > README)" >&2; exit 1; }; \
	  echo "check-docs: README.md names every reading the $$1 row can take"; \
	}; \
	check_row "Keyboard helper" '^So the helper.s row reads one of'; \
	check_row "Keyboard Setup Assistant" '^So the assistant.s row reads one of'

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

# Once per Mac. Until it has run, `make app`, `make cli`, `make helper` and `make test`
# stop with "No certificate matching".
signing-identity:
	scripts/make-signing-identity "$$(scripts/signing-identity)"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
