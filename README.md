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

## Trying the engine

    make cli
    .build/debug/lowtalker transcribe Tests/LowTalkerCoreTests/Fixtures/hello-16k-mono.wav

prints the transcript, then one line per word with its start, end, and confidence. Pass `--model` with another folder name from the whisperkit-coreml repo to try a different one.

`make cli` is `swift build` plus a re-signing step; the section below says why it matters.

### The model store

The app and the CLI share one model directory, `~/Library/Application Support/low-talker/hub`, laid out the way the Hugging Face hub lays out its cache. The first `transcribe`, or the first app launch, downloads the default Whisper model (about 626 MB) into it and records a manifest of the files and their sizes. Every launch after that checks the manifest against the files and loads straight from disk, so the app works offline once the first load has finished.

    .build/debug/lowtalker model status      # installed, missing, or damaged; exits 1 unless installed
    .build/debug/lowtalker model download    # fetch it, or finish a download that stopped

A download that stopped part way leaves no manifest, so the model reads as missing and the next download resumes it: the hub client skips every file already on disk that its own sidecar marks as downloaded. A file that later goes missing or changes size reads as damaged, and `model download` repairs it by deleting the files the manifest rejects before asking the hub client for the model; the client never hashes a file it finds on disk, so a truncated file would otherwise pass. Pass `--models-dir` to either command, or to `transcribe`, to use a different directory.

The tokenizer is not part of the manifest: WhisperKit fetches it into the same directory during the first load and reads it from there afterwards.

### Load times and the Neural Engine cache

Loading the model means Core ML compiling it for this Mac's Neural Engine, which takes minutes for the default model. macOS caches the result, keyed by the model's path and by the **code-signing identifier** of the process that loaded it, and evicts the cache after an OS update. Measured on an M2 Max:

| Situation | Load |
|---|---|
| First load of a model, after an OS update, or after the store moved | 1.5 to 4.5 minutes |
| Same signing identifier, model already compiled | 1.5 to 7 seconds |
| A binary with a new signing identifier | 2 to 4 minutes again |

`swift build` links a fresh identifier into every binary it produces, so a plain `swift run` pays the full compile after every rebuild. `make cli` re-signs the built binary with the fixed identifier `lowtalker`, which keeps the cache warm across rebuilds. The app's identifier is its bundle id, set by its certificate signature, so `make app` builds keep the cache warm on their own.

CI has no model cache, so the tests cover the mapping from WhisperKit's results onto `Transcript` with hand-built results and the manifest logic on scratch files; the real engine is only exercised through these commands.

## Microphone permission

    swift run lowtalker mic            # print the current authorization
    swift run lowtalker mic request    # prompt if never asked, then print the answer
    swift run lowtalker mic watch      # print every change until interrupted

For `mic` and `mic request` the exit status is 0 when access is granted and 1 otherwise; `watch` runs until interrupted. macOS charges a terminal command's microphone use to the terminal, so these answers are the terminal's; the app asks on its own behalf the first time it launches. macOS posts no notification when the switch is flipped in System Settings, so a change is only seen by reading the status again; `watch` reads it once a second.

To see the first-launch prompt again, forget the app's decision and relaunch:

    tccutil reset Microphone ltd.deadgrass.low-talker

## Hotkey

    swift run lowtalker hotkey                      # print each press of Right Option until interrupted
    swift run lowtalker hotkey --tap-threshold 400  # a press up to 400 ms is a tap

Each press prints `began` as the key goes down. A release after the threshold (250 ms by default) prints `ended (hold)`; a release before it is a tap, which leaves listening on until the next press of the key prints `ended (tap)`. While the command runs, Right Option never reaches the frontmost app: its down and up are swallowed by the event tap, and Left Option is untouched. The `lapses` count is how often macOS switched the tap off for a slow callback and it was switched back on; presses during a lapse are lost.

The tap needs Input Monitoring and Accessibility. macOS charges a terminal command's tap to the terminal, so the command fails with `the session refused an event tap` until the terminal has both under System Settings > Privacy & Security; the app asks on its own behalf.

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
