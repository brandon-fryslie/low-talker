# low-talker

Local push-to-talk dictation for macOS, built so voice commands can grow on top of it without ever making dictation worse.

## The atom

Hold a key, speak, release, and the words appear where the cursor is. That is the entire product for milestone 1, and it stays the thing every later feature is judged against. If a feature makes that loop slower or less trustworthy, the feature is wrong, not the loop.

Everything runs on the machine. Audio never leaves it. The app lives in the menu bar and has no window you need to look at.

## The one design rule

The chord you hold picks the mode. Your voice supplies the parameter.

Dictation and commands are never told apart by listening for magic words in the transcript. If "switch to Safari" spoken mid-sentence ever switched apps, you would stop trusting the tool for the thing you use it for most. So a command exists only in a mode that a different chord selected. Hold Right Option and everything you say is text. Hold Right Option plus Shift and everything you say is a command. Dictation's reliability is untouched no matter how many commands are added.

This rule is also what gives the recognizer a fair shot at commands. Each mode seeds the model with its own vocabulary: dictation mode with your own words and names, command mode with the names of running apps and the command keywords. A small vocabulary matched against a biased transcript is a much easier problem than spotting commands in open speech. The biasing is measured: told three names, the default model spells all three where it got all three wrong unaided, at about a tenth of a second more per pass, with the other fixtures unchanged (README, "The latency harness").

## The pipeline

Every invocation flows through the same three types, whether it is plain dictation or a command:

- **Context** is everything known before you speak: which chord was held, whether it was a tap or a hold, the frontmost app's bundle id, and the role of the focused element from the Accessibility API.
- **Transcript** is what the engine produced, with word timings and confidence attached. It is never a bare string.
- **Actions** are a small closed set of primitives. `InsertText(target)`, `SendKeys(chord)`, `ActivateApp(bundleId)`, `OpenURL`, `RunShortcut`, `Click(at, button, times)`, which presses a mouse button at a point on screen, `Scroll(at, vertical, horizontal)`, which turns the wheel there, `ClickElement(role, title)`, which clicks the centre of an Accessibility element in the frontmost app, and `Pipe`, which hands the transcript to an external program and reads a list of actions back as JSON.

A route maps a context and a transcript to actions. Dictation is the default route: any context, any transcript, insert the text at the focus. Everything in the power layer is another route in the config file, not code. Sending text to Slack is a route whose action targets Slack's bundle id. Switching apps by voice is command mode plus `ActivateApp` with fuzzy matching over the running apps. Pressing keys by voice is a keyword table in command mode whose values are `SendKeys`. A voice-plus-keyboard combination is exactly a chord-selected mode.

`Pipe` is the extensibility escape hatch. It lets a shell script or a local LLM rewrite a transcript or decide the actions, which covers most "I wish it could" requests without building a plugin system. A real plugin story waits until `Pipe` proves too small.

Configuration is one TOML file at `~/.config/low-talker/config.toml`: chords to modes and modes to routes.

## Decisions already made

**Native Swift, not a web shell.** Latency, global event taps, the Accessibility reads of focus, and the XPC link to the keyboard helper all need direct access to the OS, and Electron or Tauri would put a bridge in the hottest path.

**The engine sits behind a `Transcriber` protocol, and WhisperKit goes in first.** It runs Whisper on the Neural Engine, streams, and is Swift. NVIDIA Parakeet via FluidAudio goes in second, and it is expected to win for English push-to-talk on both latency and accuracy. Apple's SpeechAnalyzer, present on macOS 26, is the zero-dependency third option. The protocol boundary exists so that switching is a config change.

**The user chooses the delivery: an input method, or a virtual keyboard.** The choice is made at first launch and can be changed from the menu bar at any time. The input method is this app's own macOS input source, kept selected the whole time it is the delivery; it commits the words at the cursor through the text input system, the way a Japanese or Chinese input method commits a candidate — the client that terminals, browsers, Electron apps and native text views all implement — so nothing is posted as a key, the pasteboard is never touched, and no administrator is asked. That is what a managed work Mac can run, where macOS asks for an administrator to grant Accessibility or Input Monitoring. The virtual keyboard delivery is the one below, and choosing it registers the helper and shows what it still needs. An earlier decision made the virtual keyboard the only path; a Mac where nobody wants to approve a driver extension is why it no longer is. Two other grant-free routes were weighed and ranked below the input method, and neither is planned: a pasteboard promise the user resolves with their own ⌘V, which clipboard managers defeat by reading the promise early, and a macOS Service acting as the stop, which reaches only the apps that carry text Services.

**The virtual keyboard types the text through a root helper.** The keyboard is the Karabiner-DriverKit-VirtualHIDDevice driver extension, which macOS treats as hardware, so every app takes the keystrokes the way it takes a person's, no clipboard is touched, and no app needs a case of its own. A root launchd daemon, `lowtalker-keyboardd`, owns the device and the app reaches it over XPC; text becomes keystrokes on the app's side, using the console user's keyboard layout, one key report per call. The mouse takes the same path: the driver's pointing collection is a second device behind the same helper, and a click or a scroll crosses as button and motion reports the way a key does. The device knows only relative motion, and macOS applies pointer acceleration to it as to any hardware mouse, so moving to a point is a loop on the app's side that posts a report, reads the cursor's real position back, and re-estimates how far a count moves it until the cursor is within half a point. It exists because macOS protects its consent and approval dialogs from synthetic events, which is what onboarding's approvals (ticket low-keyboard-3ti.7) will meet, and the virtual mouse is hardware to macOS; the one system dialog measured so far, SecurityAgent's authentication dialog, took a synthetic click as well, so that property is still owed a demonstration (README, "The virtual mouse").

**Latency is designed for, not tuned for.** The microphone stays open into a ring buffer so key-down costs nothing. The model stays resident. Decoding streams during the hold so key-up only finalizes the last chunk. Target: under 300 ms from key-up to inserted text for a short utterance. Measured against that target with WhisperKit large-v3-turbo on an M2 Max (README, "The latency harness"): batch decodes land 0.6 to 0.9 s after key-up; streaming lands 0.3 to 0.6 s when the speaker stops before releasing the key and 0.6 to 0.9 s when speech runs to key-up, with the same words either way, except when a pass falls into temperature-fallback retries, which took one recording's streamed median to 3.7 s. It cannot go lower on this engine, because Whisper's encoder costs 0.39 s per pass over a window padded to 30 s whatever the tail's length, so the target needs an engine whose encoder is off the key-up path. That is the case the Parakeet engine has to make.

**How the hotkey is heard is a second choice, set beside the delivery and independent of it: any source goes with any delivery (`low-hotkey-aws`).** An event tap reads the keyboard at the session level, so it can hear a chord of modifiers alone — Right Option is its default — but it hears by watching every key, which needs Input Monitoring and Accessibility. A registered hot key asks the window server to notify it and so needs nothing macOS approves; the window server registers only a chord with a key in it and does not tell left from right, so its default is Option+Shift+Command+X. Either way, a press shorter than about 250 ms is a tap and toggles listening, and anything longer is push-to-talk. Fn/Globe can be the tap's key, but macOS claims it by default, so it needs a System Settings change.

**What it needs depends on the delivery and the hotkey source, and it cannot be sandboxed.** The microphone is the one grant both deliveries need. Beyond it the input method needs only its own source switched on, which the person allows in a macOS dialog naming the app, with no administrator. The virtual keyboard needs the user to approve the driver extension and the helper login item, once each. The event-tap hotkey source needs Accessibility and Input Monitoring; the registered hot key needs neither. Event taps and a root helper reached over XPC are incompatible with the App Store sandbox, so the app is Developer ID signed, notarized, and distributed outside the store.

**Feedback is minimal.** The menu bar icon shows state. A small HUD shows listening state and partial text while you speak. Nothing else appears unless something went wrong.

## Shape of the repo

- `LowTalkerCore` is a SwiftPM library with no AppKit UI: audio capture, the `Transcriber` protocol and its engines, the router, actions, and config parsing. It is unit-tested against wav fixtures.
- `lowtalker` is a CLI that transcribes a file or dry-runs a route. It exercises the whole pipeline without the hotkey, which is how routing gets debugged.
- `LowTalker.app` is the menu bar agent (`LSUIElement`), generated with XcodeGen so the project file stays diffable.

## Build order

1. **Dictation end to end.** Hotkey, audio, WhisperKit, the virtual keyboard. The three pipeline types exist from the first commit, with a single default route, so the router is never a retrofit.
2. **Parakeet.** Second engine behind the protocol.
3. **Command mode.** The config-driven router, app switching, key sending, and `Pipe`.

## Open questions

Which Whisper model to default to is answered. The latency harness (`lowtalker bench`) measured large-v3-turbo, the distilled models, small.en, and base.en over the same twelve fixtures on an M2 Max, and the default is large-v3-turbo in the whisperkit `_turbo` variant: it heard the same words as the plain variant on every fixture while decoding 25 to 30 percent sooner, and the distilled models mishear proper nouns, only their turbo variant being faster. The numbers are in the README under "The latency harness". Whether tap-to-toggle needs voice activity detection to auto-stop, or whether a second tap is enough, is still open, and gets answered by using milestone 1, not by deciding now.
