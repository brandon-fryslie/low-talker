# `make app` is the one command that turns project.yml into a launchable app bundle.
SHELL := /bin/bash
DERIVED_DATA := DerivedData
CONFIGURATION := Debug
PRODUCTS := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
# A store holding the model and the pinned driver package, for the bundle to carry.
#
# Every bundle carries its model, the development copy included. It is not an optimisation:
# `AppDelegate.loadEngine` has no other way to reach one, so a bundle built without a store
# here launches and says it carries no model rather than reaching the network. A build-time
# copy is the only door, which is what keeps a running app off the network entirely.
# [LAW:types-are-the-program] [LAW:no-silent-failure]
#
# scripts/sign-release overrides this with a store it fetched itself, pinned to the release
# it is signing; a plain `make app` fills the one below from this Mac's own store.
CARRIED_MODEL_STORE := $(abspath $(DERIVED_DATA)/model-store)
BUNDLED_MODEL_STORE := $(CARRIED_MODEL_STORE)
BUNDLED_DRIVER_PACKAGE :=

# Where `make app` takes the model from, which is where `lowtalker model download` puts it.
# A local copy, never a fetch: the CLI is what talks to Hugging Face, on purpose and by
# name, and `make app` only ever copies out of what it left behind. [LAW:one-way-deps]
MODEL_SOURCE := $(HOME)/Library/Application Support/low-talker/hub

# The two installations, as the scheme that builds each and the bundle it leaves behind.
# [LAW:one-source-of-truth] project.yml names these; they are written once here and every
# target below reads them, so a renamed product breaks in one place.
#
# `Flavor.development` is what `make app` and `make run` build, and it is the default for
# the same reason `--flavor` defaults to it: this tree is the development copy. The
# installed copy is the one that runs all day, and rebuilding it is a thing done on
# purpose, by name.
DEV_SCHEME := LowTalkerDev
DEV_APP := $(PRODUCTS)/LowTalker Dev.app
RELEASE_SCHEME := LowTalker
RELEASE_APP := $(PRODUCTS)/LowTalker.app
INSTALLED := /Applications/LowTalker.app

.PHONY: app release install run test check-docs cli helper clean signing-identity

# Regeneration is unconditional: xcodegen is idempotent and sub-second, and a
# timestamp rule cannot see removed sources or in-place rewrites of the project.
#
# One recipe for both installations, taking the scheme: they are one app built twice, and
# a second copy of these two commands is a second thing to keep in step.
# [LAW:one-type-per-behavior]
define build_app
	xcodegen generate
	xcodebuild -project LowTalker.xcodeproj -scheme $(1) -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) BUNDLED_MODEL_STORE="$(BUNDLED_MODEL_STORE)" \
		BUNDLED_DRIVER_PACKAGE="$(BUNDLED_DRIVER_PACKAGE)" build
endef

# The store the bundle carries, copied out of $(MODEL_SOURCE). Two stores and not one,
# the way `model pack` works: a store filled from Hugging Face also holds the hub client's
# own metadata, and a copy out of it takes only the files the manifests list, so the bundle
# carries exactly what an install certifies. [LAW:one-source-of-truth]
#
# Both installations build on the store they carry, so the store is their prerequisite by
# name: whichever store BUNDLED_MODEL_STORE names is the one filled before the build, and
# `BUNDLED_MODEL_STORE=` names none, which is how CI builds a bundle with no model.
# scripts/sign-release fills this same rule from the store it fetched, by passing
# MODEL_SOURCE. [LAW:dataflow-not-control-flow]
#
# Idempotent and cheap on the second run: `model download --from` is an install, and an
# install of a model already whole copies nothing. It is a directory rather than a file, so
# it is phony and asks the CLI rather than asking make to compare timestamps on 632 MB.
.PHONY: $(CARRIED_MODEL_STORE)
$(CARRIED_MODEL_STORE):
	@test -d "$(MODEL_SOURCE)" || { \
		echo "no model store at $(MODEL_SOURCE)."; \
		echo "Run '$(CLI) model download' once; it is the only thing here that reaches the network."; \
		exit 1; \
	}
	$(MAKE) --no-print-directory cli >/dev/null
	"$(CLI)" model download --models-dir "$@" --from "$(MODEL_SOURCE)"

app: $(BUNDLED_MODEL_STORE)
	$(call build_app,$(DEV_SCHEME))
	@echo "$(DEV_APP)"

release: $(BUNDLED_MODEL_STORE)
	$(call build_app,$(RELEASE_SCHEME))
	@echo "$(RELEASE_APP)"

# The release copy into /Applications, which is where it is launched from at login and so
# the path its Login Items approval and its TCC grants are recorded against. Deleted
# first rather than copied over: ditto merges into a bundle that is already there, and a
# file from a previous build that nothing in the new one overwrites is a copy of the app
# that is neither build. [LAW:no-silent-failure]
#
# The development copy is deliberately not installed. It runs from $(PRODUCTS) where
# `make app` leaves it, which is a stable path across rebuilds, and it is not a login
# item - "beside the installed one" is what it is for, not "installed twice".
install: release
	rm -rf "$(INSTALLED)"
	ditto "$(RELEASE_APP)" "$(INSTALLED)"
	@echo "$(INSTALLED)"

run: app
	open "$(DEV_APP)"

# The build comes first because `check-docs` reads the driver constants out of the CLI.
# This is why `check-docs` is a recipe line here rather than a prerequisite: a
# prerequisite would run before `swift build`, against a stale CLI or none.
#
# Signing last is what makes a test run safe to leave behind. Every link SwiftPM performs
# ad-hoc signs the product, dropping the dev identity the helper admits callers by, so
# without this a green run leaves the next `lowtalker` refused with NSCocoaErrorDomain
# 4097 - a failure reporting success. [LAW:no-silent-failure] Unconditional, because a
# recipe cannot see what SwiftPM chose to link. [LAW:dataflow-not-control-flow]
# Generating first is what lets `InputMethodPlistTests` read the plist xcodegen writes
# without generating it itself: a test that rewrote LowTalker.xcodeproj and App/Generated
# would be doing it underneath any build already running in this tree.
# [LAW:effects-at-boundaries] Unconditional and idempotent, for the reason given above
# `build_app`, and it is the same command.
test:
	xcodegen generate
	swift build
	$(MAKE) check-docs
	swift test
	$(MAKE) cli helper

# [LAW:one-source-of-truth] `lowtalker driver pins` is the source for everything about
# the driver extension's identity and the package it ships in, and README.md keeps copies
# because a reader follows the runbook by hand. This is what proves the copies still agree.
#
# Needs `swift build` first; the `test` target runs it before this.
check-docs:
	@set -euo pipefail; \
	pins=$$(.build/debug/lowtalker driver pins) \
	  || { echo "check-docs: could not read 'lowtalker driver pins' - run 'swift build' first" >&2; exit 1; }; \
	for key in bundle-id team-id io-node elements-receipt package-url package-version extension-version manager-executable; do \
	  value=$$(awk -F'\t' -v k="$$key" '$$1==k{print $$2}' <<<"$$pins"); \
	  [ -n "$$value" ] || { echo "check-docs: 'lowtalker driver pins' emits no $$key" >&2; exit 1; }; \
	  grep -qF "$$value" README.md \
	    || { echo "check-docs: the CLI pins $$key=$$value, which README.md never mentions" >&2; exit 1; }; \
	  echo "check-docs: README.md agrees with $$key=$$value"; \
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

# The CLI for engine work, and the keyboard helper it types through, as this tree builds
# them. Both are signed with the dev identity rather than ad hoc: the helper admits exactly
# the certificate that signed it, so the CLI has to carry the same one to press a key. Each
# identifier is read from its target in project.yml, which signs the copy every app bundle
# carries with it, so the two builds of one program are one code identity. For the CLI
# that identity is also what the Neural Engine keys its compiled model by, and `swift
# build` links a fresh one into every binary: unsigned, each rebuild pays the minutes-long
# specialization again. Who may call the helper is decided by the certificate, never by
# the identifier.
# [LAW:one-source-of-truth] scripts/signing-identity reads the identity name off
# project.yml; the lookups run in the recipe (not $(shell), which discards exit status)
# so a failing tool aborts loudly. [LAW:one-type-per-behavior] One recipe for both,
# taking the SwiftPM product and the project.yml target that builds the same program.
define sign_product
	swift build --product $(1)
	# Read into a variable first: a failed lookup inside the codesign line would sign as "null".
	identifier=$$(xcodegen dump --type json | jq -er '.targets["$(2)"].settings.base.PRODUCT_BUNDLE_IDENTIFIER // error("project.yml sets no PRODUCT_BUNDLE_IDENTIFIER for $(2)")') \
		&& codesign --force --sign "$$(scripts/signing-identity)" --identifier "$$identifier" ".build/debug/$(1)"
	@echo ".build/debug/$(1)"
endef

CLI := .build/debug/lowtalker
cli:
	$(call sign_product,lowtalker,lowtalker-cli)

helper:
	$(call sign_product,lowtalker-keyboardd,lowtalker-keyboardd)

# Once per Mac. Until it has run, `make app`, `make cli`, `make helper` and `make test`
# stop with "No certificate matching".
signing-identity:
	scripts/make-signing-identity "$$(scripts/signing-identity)"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
