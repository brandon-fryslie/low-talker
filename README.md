# LowTalker

Native macOS push-to-talk dictation, as a menu-bar app. What it is and why it exists is in [PROJECT.md](PROJECT.md); this file covers building it.

## Building

You need Xcode 16 or later plus `xcodegen` and `jq`, both from Homebrew.

- `make app` generates the Xcode project from `project.yml` with XcodeGen and builds `LowTalker.app` into `DerivedData/`, printing the path.
- `make run` builds and launches it.
- `make test` runs `swift build` and `swift test`.
- `make clean` removes the generated project, `DerivedData/`, and `.build/`.

CI runs `make signing-identity`, `make test`, and `make app` on a macos-15 runner for every pull request to master and every push to master; the workflow is `.github/workflows/ci.yml`.

Before the first `make app`, do the one-time setup below.

## One-time setup: signing identity

Run once after cloning:

    make signing-identity

Without it, `make app` fails with an xcodebuild error beginning `No certificate matching 'LowTalker Dev' found`.

### Why a certificate

macOS keys the Microphone, Accessibility, and Input Monitoring grants to the app's code signature, its "designated requirement". For an ad-hoc-signed build that requirement is the hash of the specific binary, so every rebuild is a new app as far as macOS is concerned and the grants are gone. For a certificate-signed build the requirement names the certificate instead, and it survives rebuilds.

### What the command does

`make signing-identity` creates a self-signed code-signing certificate named `LowTalker Dev`, valid for ten years, and imports it into the login keychain pre-authorized for `codesign`. It shows no dialogs and asks for no password. It sets no trust settings on purpose; `codesign` does not need them. Running it a second time refuses with an error, since two certificates with the same name would make builds ambiguous.

The name lives in one place: `project.yml` sets `CODE_SIGN_IDENTITY` to `LowTalker Dev`, and the Makefile reads it from there.

To confirm a build is signed with it:

    codesign -dvvv --requirements - DerivedData/Build/Products/Debug/LowTalker.app

The `designated =>` line should name `certificate leaf = H"..."`, which is stable across builds. An ad-hoc build shows `cdhash H"..."` instead, and that hash changes every build.

### Starting over

To recreate the certificate, delete `LowTalker Dev` and its private key in Keychain Access (login keychain, My Certificates), then run `make signing-identity` again. The new certificate is a new signature, so re-grant the app's permissions in System Settings.

This certificate is for local development only. Nobody trusts it and it cannot distribute the app; release builds (Developer ID and notarization) are a separate concern not covered here.
