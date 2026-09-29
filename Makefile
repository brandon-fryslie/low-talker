# `make app` is the one command that turns project.yml into a launchable app bundle.
SHELL := /bin/bash
DERIVED_DATA := DerivedData
# The one configuration project.yml defines: every bundle, the development copy included,
# is built as a release. Passed to xcodebuild and spelled into the products path below.
CONFIGURATION := Release
PRODUCTS := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)
# The certificate every bundle is signed with, when it is not project.yml's development
# identity. Empty, xcodebuild signs with the identity project.yml sets; scripts/sign-release
# names the Developer ID certificate here, and that name, the store the bundle carries and
# a DerivedData of its own are all it changes. [LAW:one-type-per-behavior] A release and a
# development build are one recipe run with two values, never two recipes.
SIGNING_IDENTITY :=
# A store holding the model, for the bundle to carry.
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
XCODE_RESOLVED_DIR := LowTalker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
INSTALLED := /Applications/LowTalker.app

.PHONY: app release install run test check-docs cli sbom check-sbom check-licenses clean signing-identity

# Regeneration is unconditional: xcodegen is idempotent and sub-second, and a
# timestamp rule cannot see removed sources or in-place rewrites of the project.
#
# One recipe for both installations, taking the scheme: they are one app built twice, and
# a second copy of these two commands is a second thing to keep in step.
# [LAW:one-type-per-behavior]
#
# [LAW:one-source-of-truth] Package.resolved decides the app's package versions, as it does
# `swift build`'s and the SBOM's. The project xcodegen writes has no resolved file, so
# xcodebuild would pick versions of its own in a fresh derived-data folder; the root one is
# copied in and xcodebuild resolves nothing else, stopping on a package it does not pin.
define build_app
	xcodegen generate
	mkdir -p $(XCODE_RESOLVED_DIR)
	cp Package.resolved $(XCODE_RESOLVED_DIR)/Package.resolved
	xcodebuild -project LowTalker.xcodeproj -scheme $(1) -configuration $(CONFIGURATION) \
		-onlyUsePackageVersionsFromResolvedFile \
		-derivedDataPath $(DERIVED_DATA) BUNDLED_MODEL_STORE="$(BUNDLED_MODEL_STORE)" \
		$(if $(SIGNING_IDENTITY),CODE_SIGN_IDENTITY="$(SIGNING_IDENTITY)") build
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
# the path its TCC grant is recorded against. Deleted
# first rather than copied over: ditto merges into a bundle that is already there, and a
# file from a previous build that nothing in the new one overwrites is a copy of the app
# that is neither build. [LAW:no-silent-failure]
#
# The development copy is deliberately not installed. It runs from $(PRODUCTS) where
# `make app` leaves it, which is a stable path across rebuilds - "beside the installed
# one" is what it is for, not "installed twice".
install: release
	rm -rf "$(INSTALLED)"
	ditto "$(RELEASE_APP)" "$(INSTALLED)"
	@echo "$(INSTALLED)"

run: app
	open "$(DEV_APP)"

# The build comes first because `check-docs` reads the onboarding readings out of the CLI.
# This is why `check-docs` is a recipe line here rather than a prerequisite: a
# prerequisite would run before `swift build`, against a stale CLI or none.
#
# Signing last is what makes a test run safe to leave behind. Every link SwiftPM performs
# ad-hoc signs the product, and the CLI's signing identifier is what the Neural Engine keys
# its compiled model by, so without this a green run leaves the next `lowtalker` paying the
# minutes-long specialization again. Unconditional, because a recipe cannot see what SwiftPM
# chose to link. [LAW:dataflow-not-control-flow] The signing is `check-sbom`'s: `sbom`
# builds the CLI through `cli` to read the default model out of it.
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
	$(MAKE) check-sbom
	$(MAKE) check-licenses

# [LAW:one-source-of-truth] The onboarding rows' readings are a vocabulary README.md keeps a
# copy of: each way macOS can answer for the microphone, and the input method switched on or
# off, and the prose lists them for a reader following the runbook by hand. This is what
# proves the copies still agree.
#
# Compared as sets in both directions, so a reading added to the code and a reading left
# standing in README after the code dropped it both fail. Empty on either side is a broken
# reader, not agreement, and says so. One loop over the rows rather than one recipe block per
# row, because the rows differ only in which lines of README hold their copy.
# [LAW:one-type-per-behavior]
#
# Needs `swift build` first; the `test` target runs it before this.
check-docs:
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
	check_row "Microphone" '^So the microphone.s row reads one of'; \
	check_row "Input method" '^So the input method.s row reads one of'

# The CLI for engine work, as this tree builds it, signed with the dev identity rather than
# ad hoc. The identifier is read from its target in project.yml, which signs the copy every
# app bundle carries with it, so the two builds of one program are one code identity. That
# identity is also what the Neural Engine keys its compiled model by, and `swift build` links
# a fresh binary every time: unsigned, each rebuild pays the minutes-long specialization
# again.
# [LAW:one-source-of-truth] scripts/signing-identity reads the identity name off
# project.yml; the lookups run in the recipe (not $(shell), which discards exit status) so a
# failing tool aborts loudly.
CLI := .build/debug/lowtalker
cli:
	swift build --product lowtalker
	# Read into a variable first: a failed lookup inside the codesign line would sign as "null".
	identifier=$$(xcodegen dump --type json | jq -er '.targets["lowtalker-cli"].settings.base.PRODUCT_BUNDLE_IDENTIFIER // error("project.yml sets no PRODUCT_BUNDLE_IDENTIFIER for lowtalker-cli")') \
		&& codesign --force --sign "$$(scripts/signing-identity)" --identifier "$$identifier" "$(CLI)"
	@echo "$(CLI)"

# What a release ships and under what license, as CycloneDX, read off the resolved
# build: Package.resolved, the checkouts `swift build` resolves under .build, and the
# CLI's default model. The CLI is built because the model's name is read from it, not
# copied, and building it is what resolves the checkouts on a clean clone. When this Mac's
# store holds the model, the rules for its two repos are held to what that install wrote.
# scripts/sbom stops and names any component sbom/rules.json cannot license.
# [LAW:no-silent-failure]
sbom: cli
	@set -eu; store="$(MODEL_SOURCE)"; [ -d "$$store" ] || store=""; \
	scripts/sbom "$(CLI)" sbom/lowtalker.cdx.json $${store:+"$$store"}

# The committed SBOM is the one the build writes, or `make test` fails: a committed file
# that can drift from Package.resolved is a maintained list wearing a generated one's name.
# Against HEAD, not the index: a regenerated file that is staged and not committed is
# still a stale commit.
check-sbom: sbom
	@git cat-file -e HEAD:sbom/lowtalker.cdx.json \
		|| { echo "check-sbom: sbom/lowtalker.cdx.json is not committed" >&2; exit 1; }
	@git diff HEAD --exit-code --stat -- sbom/lowtalker.cdx.json \
		|| { echo "check-sbom: the committed sbom/lowtalker.cdx.json is not what the build writes; commit the regenerated file" >&2; exit 1; }

# Refuses a pull request that ships a component under a license we have not accepted, or
# one whose license nobody identified. It reads the committed SBOM, which `check-sbom` has
# just held to the build, so a dependency cannot reach the tree without passing it. The
# gate's own tests run first: a gate that passes everything looks exactly like a clean tree.
check-licenses:
	python3 -m unittest discover -s scripts/tests
	scripts/check-licenses sbom/lowtalker.cdx.json

# Once per Mac. Until it has run, `make app`, `make cli` and `make test` stop with "No
# certificate matching".
signing-identity:
	scripts/make-signing-identity "$$(scripts/signing-identity)"

clean:
	rm -rf LowTalker.xcodeproj $(DERIVED_DATA) .build
