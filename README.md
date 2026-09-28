# LowTalker

Native macOS push-to-talk dictation, as a menu-bar app. What it is and why it exists is in [PROJECT.md](PROJECT.md); this file covers building it.

## Two installations

LowTalker installs twice and both copies run at the same time. The release copy is the one that runs all day, launched at login, and its chord is Right Option. The development copy is built from the working tree and runs beside it, and its chord is Right Option **and Right Command together** — hold Right Command first, because Right Option alone completes the release chord and that press then owns the hold.

They are one program, not two. What separates them is the names macOS keys an installation by — the bundle identifier, the input method's bundle identifier, input source and connection name, the ports the app and its input method answer on, and the config file — and every one of them is decided in `Sources/Flavors/Flavor.swift`. Nothing else differs. Each bundle carries its own copy of the model, as below.

The cost of the second copy is its own Microphone grant, its own input method to switch on, and one cold Neural Engine model load, that cache being keyed by signing identifier. macOS selects one input source at a time, so only one copy hears the chord at once ("The input method" below).

## Building

You need Xcode 16 or later plus `xcodegen` and `jq`, both from Homebrew.

- `make app` generates the Xcode project from `project.yml` with XcodeGen and builds the **development** copy, `LowTalker Dev.app`, into `DerivedData/`, printing the path.
- `make run` builds and launches it.
- `make release` builds the release copy, `LowTalker.app`, into the same place.
- `make install` builds the release copy and puts it in `/Applications`, which is where it is launched from at login and so the path its grant is recorded against. The development copy is deliberately not installed: it runs from `DerivedData/`, and it is not a login item.
- `make cli` builds the command-line tool into `.build/debug/lowtalker` and signs it; "Trying the engine" below uses it.
- `make test` runs `xcodegen generate` and `swift build`, then `make check-docs`, `swift test`, and finally `make cli`. Generating comes first because the suite reads the project and the plists XcodeGen writes rather than generating them itself, so a bare `swift test` on a fresh clone fails those cases; the build comes next because everything after it needs the CLI; the signing comes last because every link ad-hoc signs the product, and the CLI's fixed signing identifier is what keeps its Neural Engine cache warm ("Load times and the Neural Engine cache" below).
- `make clean` removes the generated project, `DerivedData/`, and `.build/`.

CI runs `make signing-identity`, `make test`, and `make app` on a macos-15 runner for every pull request to master and every push to master; the workflow is `.github/workflows/ci.yml`.

Before the first `make app` or `make cli`, do the one-time setup below.

## The CLI without a checkout

Each app carries the CLI at `Contents/Helpers/lowtalker`, signed as the app is. The app runs it to read its own microphone grant afresh, and a Mac with no clone of this repo can run `onboard`, `config check` and the engine commands through it:

    /Applications/LowTalker.app/Contents/Helpers/lowtalker onboard
    sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/LowTalker.app/Contents/Helpers/lowtalker /usr/local/bin/lowtalker

The copy acts on the installation that carries it: `--flavor` defaults to `release` for the one inside `LowTalker.app` and to `development` for the one inside `LowTalker Dev.app`, and a link on PATH keeps that, because the CLI resolves links before it reads which bundle it sits in. `.build/debug/lowtalker` sits in no bundle and defaults to `development`. It is one program built two ways: `make cli` builds it with SwiftPM, and each app embeds the Xcode build of the same entry over the same `LowTalkerCommands` library. The copy is in `Helpers` rather than `MacOS` because `lowtalker` and the release app's own `LowTalker` are one file name on a case-insensitive volume.

## Trying the engine

    make cli
    .build/debug/lowtalker transcribe Tests/LowTalkerCoreTests/Fixtures/hello-16k-mono.wav

prints the transcript, then one line per word with its start, end, and confidence. Pass `--model` with another folder name from the whisperkit-coreml repo to try a different one. `--vocabulary` names a term the speaker is expected to say, spelled as it should be written; repeat it for several. The engine is told the vocabulary ahead of the audio, the way a mode will tell it the user's names or the running apps, and "The latency harness" below shows what that does.

`make cli` is `swift build` plus a re-signing step; the section below says why it matters.

### The model store

The CLI keeps its models in `~/Library/Application Support/low-talker/hub`, the store `make app` copies each bundle's model out of, laid out the way the Hugging Face hub lays out its cache. A model is two parts: its weights, under `models/argmaxinc/whisperkit-coreml/<variant>`, and the tokenizer they decode with, under `models/openai/whisper-<size>` and shared by every model of that Whisper size. The first `transcribe` installs the default Whisper model (about 632 MB) into it and records a manifest of each part's files and their sizes, `installed/<model>.json` for the weights and `installed/tokenizer/<model>.json` for the tokenizer. Every run after that checks both manifests against the files and loads straight from disk, so the CLI works offline once the model is installed.

    .build/debug/lowtalker model status      # where the model stands; exits 1 unless installed
    .build/debug/lowtalker model download    # install it, or finish an install that stopped

A part whose manifest is missing or no longer verifies is taken again, and a part that verifies is left alone. A download that stopped part way leaves no manifest, so the model reads as missing and the next download resumes it: the hub client skips every file already on disk that its own sidecar marks as downloaded. A listed file that is no longer there as recorded reads as damaged, and `model download` repairs it by deleting the files the manifest rejects before fetching the part again; the hub client never hashes a file it finds on disk, so a truncated file would otherwise pass. A manifest that no longer parses is not repaired: `model download` stops and says to delete it and the folder that part lives in, and the next download starts fresh. A store written before the tokenizer had a manifest reads as damaged, "the tokenizer is not installed", and `model download` from the default source records the tokenizer already on disk without touching the network; from a published base it downloads the archive for the tokenizer in it. Two downloads may both start an install into one store; the second waits for the first. Pass `--models-dir` to any of these commands, or to `transcribe` and `bench`, to use a different directory.

By default a missing part comes from huggingface.co. `--from`, on `model download`, `transcribe` and `bench`, names another source, so a network that blocks that host still has a way to a model:

    .build/debug/lowtalker model pack --to dist                              # dist/<model>.zip, from this store
    .build/debug/lowtalker model download --from https://example.com/models/  # fetches <base>/<model>.zip
    .build/debug/lowtalker model download --from /Volumes/LowTalker/hub       # copies from another store

`model pack` writes the archive a published base serves: a store holding that one model, both parts and their manifests and nothing a hub client left beside them. A `--from` beginning `http://` or `https://` is such a base; the archive is downloaded, unzipped beside the store, and read as a store. Anything else is a directory holding a store, and only the files its manifests list are copied, after those manifests verify there. A base that answers anything but 200, or a store that does not hold the part whole, is an error naming the URL or the part. Measured on 2026-09-16, the default model packs to 477,836,162 bytes, and a store with outbound network denied except to localhost installed it from a local base, reported it installed, and transcribed with it.

Every bundle carries its model and loads it in place, the development copy included. `make app` and `make release` copy it out of this Mac's store, `~/Library/Application Support/low-talker/hub`, into `DerivedData/model-store` and build that into the bundle; `scripts/sign-release` fetches the default model into a store of its own and builds that one in instead. Either way it lands at `Contents/Resources/model-store`, where the code signature seals it with the rest of the app. The app loads the model straight from there, read-only: it writes no model data outside the bundle and never creates `low-talker/hub` for it, so a first launch with the network off needs nothing it did not ship with, deleting the app leaves nothing behind, and `codesign --verify` still passes. It rides inside the bundle rather than beside the app on the disk image, because dragging the app to Applications leaves behind anything that sat beside it. A bundle built with no store (`make app BUNDLED_MODEL_STORE=`, which is how CI builds) says at launch that it carries no model, and downloads nothing. A bundle whose store does not hold the model whole stops the load with the reason, and downloads nothing. Measured on 2026-09-16, the release bundle is 625 MB. Loading a carried store whose files are unwritable — the store the code signature seals is read-only on disk — installs nothing and takes no lock: the load and its first transcription both succeed straight off the read-only store. A carried weight file changed by one byte fails `codesign --verify`. What loading in place costs after an update is "Load times and the Neural Engine cache" below.

That the app downloads nothing is a fact of what it links, not of what it calls. Everything that writes a store — the download from huggingface.co or a published base, the copy from another store, `model pack` — is `Sources/ModelInstall`, a module only the CLI links; the app links `LowTalkerCore`, which can only read a store and load it. `AppLinksNoInstallerTests` reads Package.swift and project.yml and fails if any product the app links reaches that module. The app does link WhisperKit, whose vendored hub client stays in the binary; what this removes is every path of low-talker's own to it.

### Load times and the Neural Engine cache

Loading the model means Core ML compiling it for this Mac's Neural Engine, which takes minutes for the default model. macOS caches the result, keyed by the model's path, the files that sit there, and the **code-signing identifier** of the process that loaded it, and evicts the cache after an OS update. Replacing the files at a path it had already compiled — which is what an app update does to a model carried in the bundle — misses the cache as surely as moving them. Measured on an M2 Max with the default model; the smaller models in the table under "The latency harness" compile and load faster:

| Situation | Load |
|---|---|
| First load of a model, after an OS update, or after the store moved or its files were replaced | 1.5 to 4.5 minutes |
| Same signing identifier, same files, model already compiled | 1.5 to 7 seconds |
| A binary with a new signing identifier | 2 to 4 minutes again |

`swift build` links a fresh identifier into every binary it produces, so a plain `swift run` pays the full compile after every rebuild. `make cli` re-signs the built binary with the fixed identifier `ai.promptctl.low-talker.cli`, which keeps the cache warm across rebuilds. The copy of the CLI each app carries is signed with the same identifier, so it shares that cache. The app's identifier is its bundle id, set by its certificate signature, so `make app` builds keep the cache warm on their own.

A release that carries its model pays this compile on its first launch — a model just shipped has never been compiled here — and loading it in place pays it again after every update, because replacing the app rewrites the model files at their path and the cache does not follow them. This is the cost the copy had been hiding: a model copied into Application Support outlived an app update untouched, so an update relaunched warm; a model loaded from the bundle is replaced along with the bundle, so the first launch after each update is cold again. Measured on 2026-09-16 on an M2 Max, loading the default model from a fixed path with the CLI: 171 s cold the first time, 2.1 s once the cache was warm, and 180 s again after the model files at that path were replaced with an identical copy — the update. While the model is not yet ready, the menu bar icon is an hourglass, described to Accessibility as "LowTalker: preparing the model", and the menu's model line is the one the log records, "loading model, minutes the first time on this Mac, 0 s so far" while it loads and "ready (large-v3-v20240930_turbo_632MB) after ..." once it is resident, counted from launch, with a second line meanwhile saying a press made now is heard once the model is ready. A load that fails draws a warning triangle. A Mac that has never run low-talker also runs Gatekeeper's first check of the notarized bundle. On an Apple M5 Max running macOS Tahoe that had never run low-talker, the notarized release (v0.1.0-alpha.2) was reported to launch with no Gatekeeper prompt (how that copy reached the Mac, and so whether it carried a quarantine, is not recorded) and was ready 2 min 4 s after launch, the network on — quicker than the M2 Max here, on a newer Neural Engine. With the network off, on a Mac that had never looked up the release's notarization ticket, the image mounted with no prompt and the app launched out of it after macOS's usual first-open confirmation ("Signing for release" below).

CI has no model cache, so the tests cover the mapping from WhisperKit's results onto `Transcript` with hand-built results and the manifest logic on scratch files; the real engine is only exercised through these commands.

### The latency harness

    make cli
    .build/debug/lowtalker bench bench --model large-v3-v20240930_turbo_632MB --model base.en --runs 5

`bench` walks the directory it is given and loads every `<name>.wav` beside a `<name>.txt` holding the reference text. A fixture is named by its path under the directory without the extension, so `say/greeting`. A wav without its txt, a txt without its wav, a reference with no words, or a directory with no fixtures at all is an error, not a skipped file, so the set cannot quietly shrink. `--model` may be repeated and defaults to the app's default model. `--delivery` is how a hold's audio reaches the engine, `batch` (the whole clip at key-up) or `streamed` (a 0.1 s microphone buffer at a time, the size the tap asks for and the built-in microphone delivers); it may be repeated and defaults to both. `--runs` (default 3) is how many times each fixture is held per delivery; the first hold after a load is reported apart from the median of all runs, because after the warm load at launch the first dictation of a session pays it. `--vocabulary`, repeatable, is told to the engine on every hold, so a run with it against a run without shows what a vocabulary does to every fixture, the ones that say its terms and the ones that do not. `--models-dir` picks a different model store, as for the other commands.

Each hold is simulated in real time: a chunk reaches the engine at the moment its audio would have been captured, the key comes up with the last chunk, and the clock runs from there until the transcript is back. Stdout is one tab-separated table with a header row and one row per model, fixture, and delivery, flushed as each row lands. The columns are `model`, `fixture`, `delivery`, `audio_s` (the clip's length), `load_s` (the model load, once per model), `first_s` and `median_s` (key-up to transcript on the first hold and the median over all runs), `partial_s` (the median from the hold beginning to the first text the engine showed: the first partial, or the transcript when there was none), `wer`, its split into `substituted`, `dropped`, and `added`, and `reference_words`. Durations are seconds to three places. Stderr narrates the load phases and prints what the engine heard for every fixture with its error count, which is how a nonzero word error rate gets explained.

Streamed, the engine decodes during the hold. Whisper reads a whole window at a time, so streaming is re-reading: every pass decodes from a few confirmed words back to the speech so far, and a word two passes in a row agree on is confirmed once it ended at least a second before the later pass's end (the local-agreement rule of whisper_streaming, Macháček et al. 2023; the second is WhisperKit's `windowClipTime`, under which it decodes no window). The confirmed words a pass starts from are forced as its first tokens, decoded over the audio that contains them, and their re-reading is dropped; prompting them as earlier text instead made Whisper read them a second time out of the audio that followed ("Hello Hello world"). They are forced without their final punctuation: told "and drinking blood." and then hearing a pause, Whisper closed the transcript there and lost the seven words after the pause, while told "and drinking blood" it read the period back and went on. A pass runs whenever the engine is free and new speech has arrived, where speech is a buffer whose peak stands within 24 dB (a factor of 16) of the loudest buffer so far, judged once as the buffer arrives, plus 0.3 s of hangover for a word's soft tail. Only the loudest buffer of the utterance must reach 0.01 (-40 dBFS; room noise on the built-in microphone peaks at -49 to -54), and an utterance whose loudest never reaches it is refused with that peak, so a quiet file or a silent hold says why it has no text rather than decoding as nothing (Whisper read over silence hallucinates). Trailing quiet never starts a pass, so when the speaker stops before releasing the key, the pass in flight at key-up is the last one and key-up waits only for it to finish. During the hold the first pass waits for a second of speech, but the end of the utterance is worth a pass over whatever no pass has heard, however short: WhisperKit decodes no window that spans a second or less from its start, so a pass over less than that, the whole of a tap-to-toggle "yes", is run out to one sample past that floor with silence, the same silence the encoder pads every window with. Audio already past the floor is handed over untouched, so the guard still refuses a trailing sliver of a long clip as it did. `say/yes`, 0.48 s of speech, is heard on both deliveries where before it came back as nothing; its row in the table below is from a later run of the same command, and is one pass over the whole clip either way, so both deliveries land at 0.63 s and its first text is the transcript.

Batch against streamed, measured on an M2 Max with a warm Neural Engine cache, the default model, three holds per fixture and delivery, medians. Both deliveries heard the same words on every fixture (one error in 207, the shared "pushed to talk"). The LibriSpeech recordings end with 0.1 to 0.5 s of room quiet after the last word, the way a hand releasing a key does; the `say` clips end on the last phoneme, so on them the key comes up mid-pass and a final pass always follows.

| Fixture | Audio | Key-up to transcript, batch | Key-up to transcript, streamed | Hold to first text, streamed |
|---|---|---|---|---|
| librispeech/2277-149896-0000 | 6.6 s | 0.91 s | 0.37 s | 1.33 s |
| librispeech/251-137823-0018 | 7.5 s | 0.88 s | 0.29 s | 1.30 s |
| librispeech/2803-154328-0011 | 6.6 s | 0.82 s | 0.64 s | 2.00 s |
| librispeech/3536-8226-0018 | 9.4 s | 0.92 s | 0.54 s | 1.35 s |
| librispeech/6313-76958-0018 | 6.2 s | 0.85 s | 3.69 s | 1.32 s |
| librispeech/777-126732-0070 | 7.3 s | 0.94 s | 0.62 s | 1.33 s |
| say/app-commands | 4.0 s | 0.71 s | 0.88 s | 1.34 s |
| say/greeting | 2.0 s | 0.59 s | 0.60 s | 1.52 s |
| say/jargon | 4.7 s | 0.72 s | 0.78 s | 1.34 s |
| say/meeting-request | 4.4 s | 0.67 s | 0.92 s | 1.33 s |
| say/short-reply | 1.9 s | 0.58 s | 0.78 s | 1.52 s |
| say/status-update | 8.1 s | 0.91 s | 0.87 s | 1.33 s |
| say/yes | 0.5 s | 0.63 s | 0.63 s | 1.11 s |

Where a pass's time goes, from a probe of one pass over the 4.4 s clip: the log-mel spectrogram 0.04 s, the encoder 0.39 s, twenty decoder steps 0.23 s, so 12 ms a token. The encoder always sees a window padded to 30 s, so 0.39 s is the floor of any pass that hears new audio however short the tail is, and a forced prefix token costs a decoder step like a decoded one. A pass over a few words of tail is therefore about 0.5 s, not much under a batch decode of a short clip, and streaming does not win by making the key-up pass small. It wins when the pass in flight at key-up is the last one: key-up then waits only for that pass to finish, anywhere from nothing to one pass, which is the 0.29 to 0.64 s medians on five of the six recordings. When speech runs right up to key-up, key-up waits for the pass in flight and then one more, so the `say` clips land between 0.04 s ahead of batch and 0.25 s behind it. The first text lands 1.30 to 1.35 s into the hold on the longer clips: the first pass starts once 0.7 s of speech plus the hangover has arrived and takes about 0.5 s. It is 1.52 s on the two-second `say` clips, and 2.00 s on librispeech/2803, whose first pass, over 0.3 s of speech after half a second of leading quiet, takes 1.0 to 1.2 s where the same cut of another recording takes 0.6 s. Under 300 ms from key-up needs the encoder off the key-up path, a smaller or a genuinely streaming encoder, which is the case the Parakeet engine has to make. The other hazard in this run was WhisperKit's temperature ladder, since switched off (see below): its retries hit two of librispeech/6313's three streamed holds, the first at 5.29 s, and are the whole of that row's 3.69 s median.

The vocabulary check is two full runs of the bench under the same conditions, one bare and one with `--vocabulary Brynleigh --vocabulary Fryslie --vocabulary Jaxxon`. The vocabulary reaches Whisper as its initial prompt, the text of a segment before the utterance: the terms space-joined, each with the leading space a spoken word carries, so " Brynleigh Fryslie Jaxxon". A comma-separated list read its commas back into the transcript. WhisperKit keeps at most 111 prompt tokens, and the transcriber refuses a longer vocabulary rather than let it lose its first terms silently. `say/names` reads "Ask Brynleigh Fryslie to review the pull request before Jaxxon merges it." Bare, the engine heard "Ask Brynley Frisley to review the pull request before Jackson merges it." batch, 3 of 12 words wrong, and "Ask Brian Lay Frisley ... Jackson" streamed, 4 wrong. Told the three names, it made 0 errors on both deliveries. The other twelve fixtures heard the same words with the vocabulary as without: the only error in either run is the shared "pushed to talk" on `say/jargon`, and none of the three names appeared in a fixture that does not say them.

The cost is decoder steps. Brynleigh, Fryslie, and Jaxxon are 10 tokens, plus the start-of-previous token, so 11 decoder steps a pass, about 0.13 s at 12 ms a token. Batch key-up to transcript rose 0.07 to 0.17 s per fixture (`say/meeting-request` 0.67 s to 0.78 s, `say/names` 0.71 s to 0.88 s). Streamed medians rose 0.1 to 0.4 s on most fixtures (`say/greeting` 0.59 s to 0.99 s, `say/meeting-request` 0.90 s to 1.16 s, `say/status-update` 0.78 s to 1.12 s), because every pass pays the prompt and key-up sometimes waits for two. One streamed row in each run was a temperature-ladder outlier, librispeech/6313 at 4.15 s bare and librispeech/777 at 2.16 s with the vocabulary, the hazard the next paragraph turns off. First text landed 1.43 to 1.46 s into the hold on most clips against 1.30 to 1.35 s bare, and later on four whose first pass retried (librispeech/251 4.70 s, librispeech/777 3.07 s, `say/status-update` 4.71 s, `say/jargon` 2.44 s). Getting these numbers meant working around a WhisperKit 1.1.0 bug: with a prompt set it writes each decoder step's alignment row at the step's index in the whole prefilled sequence, prompt included, but reads word timings by the token's index from the start-of-transcript token, so every word was read 11 rows early, the 2 s clips came back with no words, and streamed passes dropped tail words with latency up to 10.7 s. `PromptOffsetSegmentSeeker` in LowTalkerCore hands WhisperKit's own seeker the rows from the start of the transcript on. Upstream has no fix as of September 2026.

The temperature ladder is off: one decode a pass, at temperature zero. By default WhisperKit re-decodes a window at rising temperatures, up to five more times, when the reading looks repetitive (compression ratio over 2.4) or under-confident (mean log probability under -1.0), and a first token under -1.5 aborts a decode at once so the next rung starts sooner; each rung is a full decoder loop over the same encoder output. A probe of every pass in a five-hold bench found the ladder climbed on nothing but mid-hold passes cut into a word. The first pass over librispeech/2803, 0.6 s of "The jailer" after half a second of quiet, took three to five rungs on every hold, 1.0 to 1.2 s, to read "the gym", and at the fifth rung nothing at all; the pass over librispeech/6313 that ends inside "indignation" took two to five rungs, 1.5 to 4.4 s against 0.6 s for a plain pass, and at the top rung read "Lumpy, filled with, filled with, Filled with ignatation that, Anyone should". Not one of the seventy batch holds, each a single pass over a whole utterance, climbed it. So `temperatureFallbackCount` is 0 and `firstTokenLogProbThreshold` is nil, the abort having nothing to abort for. Five holds per fixture and delivery, before and after, on the fourteen fixtures: the word error rate is the same on all 28 rows and the transcripts differ by one comma; the longest pass is 1.37 s where it was 4.40 s; librispeech/6313 streamed is 0.37 s first and 0.90 s median where it was 1.27 s and 1.82 s; and librispeech/2803's first text lands 1.3 s into the hold where it was 2.0 s, its first pass 0.5 s instead of 1.0 to 1.2. What the ladder was catching shows once: at temperature zero that 6313 pass reads "Lumpy, filled with, filled with, filled with", a loop, in 0.9 to 1.4 s, and the next pass 0.7 s later reads the sentence, so the loop is on screen as a partial for under a second and never in a transcript. A loop on a final pass, the one no later pass corrects, would be delivered as read, and that is the accepted trade: on the looping 6313 pass the ladder's rungs read back a truncated "Lumpy, filled with", the stutter quoted above, or on librispeech/2803 nothing at all, so its answer to a loop was a shorter or empty reading at one full decode per rung, and in dictation a visible loop is redone where a clause silently gone is not noticed. Streamed key-up on the recordings that end in room quiet moved both ways between the two runs (librispeech/2277 0.27 s to 0.69 s, 3536 0.32 s to 0.84 s) with every pass identical in count, cut, and duration: on those the number is whether the last pass happened to start just before key-up or just after, and it is the harness's phase, not the ladder's. For the next probe: `timings.totalDecodingFallbacks` is the index of the last rung that fell, so a pass that retried exactly once reports 0.

The speech gate follows the utterance: a buffer is speech when its peak stands within 24 dB of the loudest buffer so far, and only the loudest must clear an audible floor of -40 dBFS, where before every buffer had to reach -34 dBFS on its own. A ratio does not move when the level does, so a soft speaker or a low-gain microphone is cut into the same speech and quiet as a loud one, and a fixed level is not: streamed over the bench fixtures attenuated by 20 dB, the old gate returned librispeech/2277, 3536, and 777 with key-up 0.000 s, no final pass having run, because their soft trailing buffers fell under -34 and the words after the last loud buffer plus the hangover were never decoded, 7 words lost in all ("future"; "his minister's domestic arrangements"; "like that"). A gate relative to the utterance's own noise floor was the other candidate, and it fails because the `say` fixtures have no quiet in them: say/meeting-request's softest 0.1 s buffer is -13.8 dBFS and its loudest -2 to -4, so any rule that accepts it and refuses a silent room (-47 to -54 dBFS in every buffer, also no contrast) must contain an absolute level, and the absolute sits on the one question only level can answer, whether there is a speaker at all, asked once of the loudest buffer; so `Utterance.audible` is 0.01 and `Utterance.dynamicRange` is 16. The 24 dB came from simulating the rule buffer by buffer over all fourteen fixtures against the old gate, for ranges of 20 to 32 dB: at 24 dB, 18 buffer judgements out of about 800 differ, all mid-utterance, and the last speech buffer moves back by one on three `say` fixtures whose final buffer is already inside the 0.3 s hangover, so the last pass covers the same audio; at 20 dB six fixtures moved; at 28 dB and above speech ends moved later on librispeech/777 and 251. The softest LibriSpeech speech under the old gate sat 19 to 27 dB under its utterance's loudest. With the new gate, five holds on both deliveries, the 20 dB attenuated set scores the same word error rate as the original on 26 of 28 rows, every LibriSpeech fixture at 0 errors both ways; the two rows that differ are say/names, whose unaided names flip between runs at full level too. At 30 dB down, the loudest buffer at -42.8 dBFS, the utterance is refused. A silent hold costs what it did: 2.9 s of steady room noise at -47 to -53 dBFS is refused with peak 0.0043 before any decode, and on the original fourteen fixtures the word error rate is identical on all 28 rows against the previous run. The trade is in what a peak knows, which is level: a click at or above -40 dBFS is a speaker, an exposure the -34 gate had too (room clicks and typing measured -25 to -40 dBFS a buffer, so it is not new in kind); and a soft speaker whose room noise sits within 24 dB of their loudest gets passes over trailing quiet. The range cuts the other way too: the loudest clip never falls, so a transient louder than any word, a door or a dropped object, sets the bar for every clip after it, and speech more than 24 dB under it is trimmed as quiet. A transient at -10 dBFS puts speech at the old gate's -34 out of range; one at full scale puts speech under -24 dBFS out of range. Speech before the transient stays speech and the pass over the speech through it still runs, so the exposure is a soft speaker, loudest word under -24 dBFS, losing the words after a near-full-scale slam that the old gate would have heard; the fixtures at full level peak at -2 to -12, inside the range of anything.

Word error rate is (substitutions + deletions + insertions) / reference words, by minimum edit distance over words, with reference and hypothesis normalized the same way first: lowercased, a word being a run of letters, digits, and apostrophes, so hyphens and punctuation separate. An apostrophe at a word's edge is a quotation mark and is dropped; inside a word it is a contraction and stays.

The fixtures live in `bench/`. `bench/say/` holds eight utterances written as `.txt` files and rendered to 16 kHz mono wav with the Mac's `say` command (voice Samantha) by `scripts/make-bench-fixtures`; `say/names` is the one with names Whisper cannot spell unaided, for the vocabulary check above, and `say/yes` is the one under a second, which keeps sub-second speech heard. There the text is the source and the wav is derived, but the wav is committed because a synthesizer voice changes with the OS and the numbers are only comparable over the same audio. `bench/librispeech/` holds six human utterances from the LibriSpeech corpus (dev-clean split), one per speaker, with their transcripts, converted to 16 kHz mono wav; these are recordings, so the wav is the source and the txt is its transcript. LibriSpeech is CC BY 4.0 (Panayotov, Chen, Povey, Khudanpur, 2015). Synthesized speech turned out too clean to rank the models on accuracy: small.en and base.en score exactly as the large models do on it, and only the distilled pair adds an error; the human recordings are what separate them.

Measured on an M2 Max with a warm Neural Engine cache, five runs per fixture, twelve fixtures totaling 207 reference words: the set before `say/names` and `say/yes` were added, so the same command today scores fourteen fixtures and 220 words. Key-up to transcript is the median for the 4.4 s fixture `say/meeting-request`; word errors are the total over all twelve fixtures. Every model shares one error, the synthesizer's rendering of "push to talk" that all six hear as "pushed to talk", so 1 is the floor.

| Model | Warm load | Key-up to transcript, 4.4 s clip | Word errors of 207 |
|---|---|---|---|
| large-v3-v20240930_626MB | 1.6 s | 0.97 s | 1 |
| large-v3-v20240930_turbo_632MB | 2.1 s | 0.68 s | 1 |
| distil-large-v3_594MB | 0.9 s | 1.05 s | 3 |
| distil-large-v3_turbo_600MB | 1.4 s | 0.58 s | 3 |
| small.en_217MB | 1.0 s | 0.49 s | 4 |
| base.en | 0.8 s | 0.17 s | 7 |

Cold loads, the first load of a model on this Mac: turbo_632MB 171 s, distil 594MB 74 s, distil turbo 107 s, small.en 22 s, base.en 12 s; the 626MB variant was already cached. The distilled models heard "Low Talker" as "Loh Talker" and "Trevelyan" as "trevalion"; small.en also heard "hissed Lumpy" as "his plumpy"; base.en heard "hissed Lumpy, filled with indignation" as "his slumpy, filled with dignity and nation".

The default is now `large-v3-v20240930_turbo_632MB`, replacing `large-v3-v20240930_626MB`. The `_turbo` suffix in the whisperkit-coreml repo names a variant that carries an extra `TextDecoderContextPrefill.mlmodelc`, a prefilled decoder context, over the same encoder and decoder weights as the plain variant, which is why it produced identical words on every fixture while decoding 25 to 30 percent sooner. The distilled models mishear proper nouns, the failure that matters for dictation, and only their turbo variant is faster than the default. The sub-300 ms target is out of reach for a smaller model and, as the streamed numbers above show, for streaming with this encoder too.

## Microphone permission

    swift run lowtalker mic            # print the current authorization
    swift run lowtalker mic request    # prompt if never asked, then print the answer
    swift run lowtalker mic watch      # print every change until interrupted

For `mic` and `mic request` the exit status is 0 when access is granted and 1 otherwise; `watch` runs until interrupted. macOS charges a terminal command's microphone use to the terminal, so these answers are the terminal's; the app asks on its own behalf, from the microphone step of its guided setup ("The guided setup" below), and never at launch. macOS posts no notification when the switch is flipped in System Settings, so a change is only seen by reading the status again; `watch` reads it once a second.

To see the app's microphone step and its prompt again, forget the app's decision and relaunch:

    tccutil reset Microphone ai.promptctl.low-talker

## The microphone indicator

    swift run lowtalker mic indicator              # dark at rest, lit during the hold, dark after
    swift run lowtalker mic indicator --hold 5000  # hold the press for five seconds instead of one

checks the three things the microphone work promises about the menu bar, which are facts about a device and no test in the repo can reach: every `AudioCapture` test runs against fake hardware, and CI has no microphone. It asks for microphone authorization, prompting on a Mac that has never been asked; reads the indicator; starts capture with the resting mode pinned to `shut` whatever the config file says; reads the indicator again, with a microphone readied and no press open, which is the reading called "at rest"; opens a session, which is a press; waits out `--hold`, in milliseconds, 1000 by default and required positive; reads the indicator during the hold; ends the session; and reads it after. The promise is dark at rest, lit during the hold, dark after, and when it held the whole output is one line:

    at rest: dark, during the hold: lit, after the hold: dark

The exit status is the verdict: 0 when all three readings are what was promised, 1 when any of them is not. A broken reading adds a line naming the moment, what was promised there, and what that particular fault means, because the three break for three different reasons.

What it reads is `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device, the device a press opens. It is true while any process on this Mac has that device running, and it is the property the menu-bar microphone indicator and the privacy report follow. It is not the app's own bookkeeping, which is exactly why it can answer the question — `AudioCapture.state` says only what capture believes.

For the same reason a default input device already running before anything has been readied is a refusal rather than a reading. The property says only that the device is running somewhere, so nothing can tell this process's hold from whatever had it first; the command takes no readings at all and names the command that identifies the holder:

    /usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "PublishRecordingClientInfo: Report client"'

spelled `/usr/bin/log` because `log` is a zsh builtin and zsh is this Mac's shell. On a Mac with no input device the reading throws — "this Mac has no default input device" — rather than reporting a dark indicator; that arm has not been run on a Mac without an input device.

It is not part of `make test` and must not become part of it: CI has no microphone, and a unit test that faked the property would be a second fake wearing a hardware check's name. The unit tests cover the report alone, the table of what is promised at each moment and the lines it prints, and nothing in them fakes the property. The command says what the device did, not what was heard; `lowtalker record` is the command that says whether the audio came back whole. Before it existed these promises were checked with binaries written for one run and then deleted, and what survived was a sentence in a commit message; one such message claimed presses came back whole while its own last line admitted none had run on a Mac.

Measured on an M2 Max with the built-in "MacBook Pro Microphone" as the default input: dark at rest, lit during the hold, dark after, exit 0, on five runs — four at the default 1000 ms hold and one at 5000 ms. Three of those ran back to back and each one's refusal check passed at the start, so the device was read as dark within milliseconds of the previous run's exit: it goes dark as the hold ends, with no settling delay for the reading to wait out. A screenshot of the menu bar taken three seconds into a five-second hold shows the orange microphone dot, and one taken after that hold shows it gone, so the property was cross-checked by eye rather than only through itself. The at-rest reading is the first measurement of a claim the code had only asserted, that readying a microphone — finding the component, binding the device, `AudioUnitInitialize` — opens no device and lights nothing.

The first four attempts refused, correctly, and each refusal was true. coreaudiod named the holders in turn: first LowTalker.app itself, a build from Sep 8 predating the change that taught the microphone to close, holding the microphone while idle, which is the original complaint this whole body of work exists to fix, caught live by the instrument's first run; then a separate voice tool running on the machine; then macOS's own Sound settings pane, whose input-level meter holds the microphone for as long as System Settings is open on it.

## Hotkey

    swift run lowtalker hotkey                      # print each press of the hotkey until interrupted
    swift run lowtalker hotkey --tap-threshold 400  # a press under 400 ms is a tap

Each press prints `began` as the key goes down, with how long after its own stamp it was delivered. A release after the threshold (250 ms by default) prints `ended (hold)`; a release before it is a tap, which leaves listening on until the next press of the chord prints `ended (tap)`. A chord is modifier keys alone, and pressed with another modifier already held it is a different chord.

Which chord that is depends on the installation, and the CLI built here defaults to the development one: `lowtalker hotkey` watches Right Option and Right Command together unless `--flavor release` is passed, in which case it watches Right Option alone. Every command that reads a config takes the same `--flavor`, and defaults the same way: to the installation whose app carries the binary, and to the development copy for `.build/debug/lowtalker`, which no app carries ("The CLI without a checkout" above).

The command hears the way the app does, through this installation's input method ("The input method" below), so it needs no grant and hears only while that input method is selected and an app that takes typing is in front. It hosts the port the app would, so it is refused by name while that installation's app is running.

## The config file

    make cli
    .build/debug/lowtalker config check

reads this installation's file in `~/.config/low-talker` — `config.dev.toml` for the copy built from this tree, which is what `.build/debug/lowtalker` defaults to, and `config.toml` for the installed one under `--flavor release` — and prints what the app would run with. It starts nothing. `--path` reads some other file instead, which is how a file is checked before it is installed, and it needs `--flavor` said out loud: which installation a file is read as decides every default it does not set, and the command refuses to guess. No file at all is not an error: the app runs on the defaults, dictation on this installation's own chord with the default model. A file that exists but cannot be read, or cannot be understood, is an error and is never quietly replaced by the defaults, since a config the user wrote and the app silently ignored is worse than one it refuses.

The file names a `model`, a model folder name such as `base.en`, an optional `[microphone]` table saying what the device does between presses, and an array of `[[modes]]` tables. Each mode takes a `name`, an optional `chord`, an optional `vocabulary` of terms, and an optional `routes`.

    model = "base.en"

    [[modes]]
    name = "dictation"
    chord = { modifiers = ["rightOption"] }
    routes = [{ when = "always", then = { insert = "focus" } }]

    [[modes]]
    name = "notes"
    chord = { modifiers = ["leftCommand", "leftShift"] }
    vocabulary = ["Kubernetes", "Anthropic"]

A chord is modifier keys, at least one. The input method is told only when a modifier key moves, so a key besides them could never complete a chord, and a `key` is refused as a word the schema has no place for. It is the chord the app and `lowtalker hotkey` listen for and the menu names. A mode with no `chord` listens for this installation's own, so only one mode may leave it out: two would listen for one chord, and the file is refused naming the second. A route's `insert` is either the word `"focus"`, whatever has focus when the route fires, or a table naming an app by bundle id. The input method reaches only the cursor of the app in front, so a route naming an app is refused at the press, by name, with nothing inserted. A key the schema has no place for is refused rather than ignored, so a typo is told rather than silently doing nothing. A chord written under a hotkey source's name, `chord = { inputMethod = { … } }`, the way a config named one per source before the input method was the only way the chord is heard, is refused as `modes[0].chord.modifiers is missing`.

The `[microphone]` table is optional, and the file above leaves it out: with no table at all the microphone is `shut`, opened when the hotkey goes down and closed when it comes up, so the indicator in the menu bar is a record of what you dictated rather than of how long the app has been running. `at_rest = "open"` takes the trade the other way and holds the microphone from launch to quit. What that buys is the look-back, the 0.3 s of already-captured audio a press reaches back over, so a key pressed a syllable into a word still catches that word; what it costs is a lit indicator and a privacy report saying low-talker is listening on a Mac nobody has spoken to. There is no wake word yet, so `at_rest` is the only thing that holds the microphone open while nobody is dictating: it is in the file or it does not happen. The key is required once the heading is there. A `[microphone]` with nothing under it is refused as `microphone.at_rest is missing`, since a heading somebody wrote on purpose cannot be read as the default they were already getting, and any other word is refused with that word quoted back, as `microphone.at_rest: "sometimes" is not something the microphone does at rest`.

Where a fault is reported depends on how far reading got. A file that is not TOML at all names the line reading stopped on. Anything that is TOML but wrong is named by its path in the document instead, as `modes[1].routes[0].when: "sometyme" is not something a route can match on` or `modes[1].name is missing`, and carries no line number: decoding reports the path it was at, and the TOML library exposes source positions only for a parse error, not for a document that parsed. The path counts `[[modes]]` entries from zero, the way the file writes them, so the entry it names is one the reader can count to.

A file can also parse and still say something nobody meant, and those gaps are reported too. A mode whose `routes` is an empty list claims nothing: it listens, and nothing it hears becomes anything. A mode with no `routes` key at all dictates instead. The two look almost alike in a file and mean different things, which is why the report tells them apart. A bundle id no app on this Mac answers to is reported as well; that one is checked against the machine rather than against the file, which is why it is the check command's own work and not something reading the file could ever have found.

Every heading is printed every time, so a mode with no vocabulary shows an empty `vocabulary:` rather than leaving the reader to wonder whether the key was read and ignored. On the file above, read by the development copy, with a mode inserting into an app this Mac does not have and a mode with no routes added after it:

    /Users/you/.config/low-talker/config.dev.toml

    model: base.en
    microphone: open only while you dictate

    mode "dictation"
      chord: rightOption
      vocabulary:
      routes:
        always → insert into the focused element

    mode "notes"
      chord: leftCommand+leftShift
      vocabulary:
        Kubernetes
        Anthropic
      routes:
        always → insert into the focused element

    mode "ghost"
      chord: rightCommand
      vocabulary:
      routes:
        always → insert into com.example.nope

    mode "silent"
      chord: function
      vocabulary:
      routes:

    gaps:
      mode "ghost" inserts into com.example.nope, which no app on this Mac answers to
      mode "silent" has no routes, so nothing said in it becomes anything

The exit status is 0 when the file is understood and has no gaps, 1 when it cannot be understood, and 2 when it is understood but has gaps.

### Reloading as it is edited

    .build/debug/lowtalker config watch

prints the same report and then stays up, printing it again each time the file is saved into something different. The app reads the file once, at launch, for the microphone and the chords alike, and a save after that does not reach it; teaching it to keep up with the file as it is edited is low-app-3sp.5's work, and for now this is where a chord can be changed and seen to take effect.

A save that cannot be understood does not disturb what is running. It is named the way `check` names it, followed by the file still in force:

    refused: line 2 is not TOML: Error while parsing table header: expected ']', saw '\n'
    still running: /Users/you/.config/low-talker/config.dev.toml

Which is the whole point of reloading this way rather than re-reading the file and taking whatever comes back. A config half way through being typed is refused a hundred times over the course of an edit, and if a refusal cost the author their settings the feature would be worse than not having it. The defaults are reached by deleting the file, never by mistyping it.

Deleting the file reloads too, back to the defaults, and the report says the file is gone rather than showing the defaults as though somebody had written them. Creating a file where there was none is picked up as well, and so is creating `~/.config/low-talker/` itself: the watch is placed on the deepest directory of that path that exists, because a watch on a directory that is not there yet is deaf for the life of the process. Saves that change nothing — the file rewritten with the same bytes, or some other file in the same directory — are read and not reported, so what gets printed is the set of changes to what the app would run with, not the set of times the disk was touched.

## Dry-running a route

    make cli
    .build/debug/lowtalker route --context '{"chord":{"modifiers":["rightOption"]},"press":"hold","frontmostApp":"com.apple.TextEdit","focusedElementRole":"AXTextArea"}' --text "hello from the router"

prints the actions the router decides for that context and text, as the JSON array a Pipe program would hand back, and performs none of them. The app performs a route's actions through the input method: `insertText` at the focus is put at the cursor, and every other action - text for a named app, `activateApp`, `openURL`, `runShortcut`, `pipe` - is refused by name before anything is inserted, so a route is never half performed.

## The input method

LowTalker puts what you dictate at the cursor through its own macOS input method, and hears the chord through the same one. The input method is a small second bundle the app carries; the app copies it into `~/Library/Input Methods`, registers it, and - once you have switched it on in setup, the one step macOS asks you about - selects it at every launch and keeps it selected. Its controller passes every key through untouched, so typing is unchanged while it is the selected source. Nothing is posted as a key, nothing asks for an administrator, and the pasteboard is never touched.

While it is the selected input source, macOS hands the input method every change of the modifier keys, and it tells the app over a port the app hosts (`ai.promptctl.low-talker.hotkey`, `.dev.hotkey` for the development copy), which hears only that installation's input method. A press is not heard while another input source is selected, where the app in front takes no typing, or while an app holds Secure Event Input, as a password field does. The menu reads the first and the last each time it opens and names whichever stands under its Hotkey line, as `Not heard now: another input source is selected`. A release is heard wherever it happens, since the app reads the modifier keys itself while one is held. macOS selects one input source at a time, so the two installations cannot both hear at once: the one whose input method was selected last hears.

Hold the chord while you speak, or tap it to start and again to stop.

An installation from before the input method was the only way still holds its old answers in its defaults, under `inputMethod` and `hotkeySource`. Nothing reads them now, so it comes up on the input method with no question asked.

## Dictation

The app runs the loop: hold the chord, speak, release, and what was said is inserted at the cursor. Key-down marks where the utterance begins on the audio ring and reads which app is in front; key-up ends the mark, and the clip is heard, routed and inserted while the next press can already begin. Sessions are heard and inserted on one serial queue, so two presses in quick succession insert in the order they were spoken however long the engine takes on either. Each session is one line in the unified log under the `dictation` category: how many words were heard, how long after key-up, and which app's cursor took them.

The loop is its own module, `Sources/Dictation`, and the microphone, engine, router, executor, frontmost-app reader and the reporter that hears the outcome are values it is given, so the whole of it runs under `swift test` against a fake of each.

## Insert

Inserting needs no grant at all. The app asks the input method to put text at the cursor through the text input system, the way a Japanese or Chinese input method commits a candidate, so nothing is posted as a key and the pasteboard is never touched. The LowTalker input source has to be selected for it; the input method process launches on demand.

The input method takes words only from its own installation's app. The name the app sends to can be computed by any process, so every request is checked against the sender's code signature before its words are read. The sender has to be the app's bundle identifier, signed by the certificate that signed the input method, under the hardened runtime. The signature is the one the kernel holds for the running process, because the input method's sandbox cannot read the sender's executable from disk. Anything else is refused with `senderIsNotThisInstallationsApp`, and the input method's log names the pid it turned away, who that process is, and who it needed to be. The check runs the other way too. A name anyone can compute is one anyone can hold first, so before sending any words the app asks whoever holds the name who it is. If the answer is not from its own input method, signed as the app is, the app sends nothing. There is no command-line `insert` for the same reason. A command any process can run would let any process type.

When an insert fails, the app reports why by name, because either way the words are not at the cursor. A refusal says why: no client has focus, the cursor is in an app that is not in front, an app has secure keyboard entry on, or the sender is not this installation's app. A transport failure says which one it was, because a request the input method never took means the words did not land, while an answer that never came back means they may have.

What `inserted` claims is that the client belonging to the app in front accepted the commit, not that a person saw the words - the text input system offers no delivery report. The Finder's desktop, in particular, presents a full text client that accepts text into a buffer nobody can see.

Verified on this Mac with the development copy, 2026-09-24: a held chord over the fixture `say/greeting`, played to the microphone, landed the words at the cursor in TextEdit, Safari, Chrome and iTerm2, confirmed in the input method's log, with TextEdit reading back "Hello world, this is Low Talker." — and in VS Code. Those are the apps the slice's checkpoint covered, chosen because they span the cases the input method has to reach: a native text view, a WebKit browser, a Chromium browser, an Electron editor, and a terminal. An app left running through an earlier build's input-method restarts is shut out by macOS's `imklaunchagent` until it relaunches or the user logs out, so each app is relaunched before the run, or its refusal measures that history rather than this build. Secure Keyboard Entry, which iTerm2 can turn on, is its own named refusal (above); toggling it is left to the operator.

## What is left to set up

    make cli
    .build/debug/lowtalker onboard

prints everything that must hold before low-talker can hear and type, read off this Mac now, with the step for whatever is missing indented under it:

    Microphone: only the app can read this; see Set Up in its menu
    Input method: switched on

Every row is `Name: what was read`. The exit status is 0 when nothing the CLI can read is left to do and 2 when something is. The microphone row is the app's own: macOS keys the Microphone grant to the app that holds it, so a CLI asking would be told about its terminal. It is named and never read from here, and the menu and the guided setup read it. Every row is printed every time, met or not, since a list that showed only what was wrong leaves a reader unable to tell "checked and fine" from "never checked". A fact that could not be read is a row of its own reading `could not be read`, with the reason as its step, and it never counts as met, so a reading nobody managed to take can never come out as ready.

The menu-bar app's status menu shows the same list in the same words. All three surfaces, the CLI, the menu and the guided setup, read one list, assembled in `OnboardingProbe.readiness` and nowhere else. The menu holds no state either. It is emptied and rebuilt from a fresh reading every time it is about to be shown, in `NSMenuDelegate.menuNeedsUpdate`, rather than cached, because a cached reading is stale exactly when it matters: right after the user has given the grant the menu was telling them to give.

### The guided setup

The app launches without raising any system dialog: no Microphone or input method prompt. Launch reads every grant, which asks nothing, and brings dictation up as far as what is already granted allows. What is missing is asked for from Set Up LowTalker… in the menu (Set Up LowTalker Dev… for the development copy), which opens on its own at a launch that finds something missing, since nothing can be dictated until both steps are met. The menu item says how many steps are left.

The setup is a walk over the same list the menu shows, one requirement per page. Each page says why the app asks, what the grant lets you do, and what still works if you skip it, before the button that makes macOS ask. Pressing that button raises one system dialog, naming the app. Skip for Now moves on and leaves the app running; skipped steps wait on the last page, each with what skipping it costs and a button back to it. The page is redrawn from a fresh reading whenever the window comes back to the front, so a switch turned on in System Settings clears its step there without a relaunch. When a reading after a request, on coming back to the front, or on opening the menu finds a grant the previous reading of the same setup did not, dictation comes up behind it. The microphone's dialog is shown once per app, so once its step has been asked in a walk and is still unmet, its button becomes Open System Settings and the page says why. The input method is the exception: macOS shows its Allow dialog again on the next press (measured on studious, 2026-09-27), so its button stays and the page never sends the person to System Settings with "asks only once".

| Step | What the button does |
|---|---|
| Microphone | asks for the microphone (`AVCaptureDevice.requestAccess`) |
| Input method | switches this installation's input method on (`TISEnableInputSource`), which macOS asks about in a dialog naming the app; it asks again after a No, and a source first installed during this login session switches on only after the next login, with no dialog until then |

Those are the only places the app calls anything that can put a dialog on screen. The input method is copied and registered at launch but never switched on there.

So the microphone's row reads one of four things:

- `allowed` means the app can hear.
- `not asked yet` means macOS has never been asked, and the setup's Allow button is what asks.
- `turned off` means the person declined or switched it off since, and only System Settings > Privacy & Security > Microphone turns it back on.
- `restricted by policy` means whoever manages this Mac has forbidden it.

So the input method's row reads one of two things:

- `switched on` means macOS lists this installation's input method and its one mode as on, and the app selects the mode itself.
- `switched off` means either is not on yet, whether or not it has been copied and registered: never allowed, or removed under Keyboard > Input Sources, which switches the mode off.

The app logs every reading it takes, so an agent can read back what the menu is showing without a screen:

    /usr/bin/log show --predicate 'subsystem == "ai.promptctl.low-talker"' --last 5m --style compact

The category is `engine`. Each open writes `onboarding: ready` or `onboarding: not ready`, then one `onboarding: <Name>: <what was read>` per requirement, then `hotkey: unheard because [...]` with whatever the Hotkey line names. `log` is spelled with its absolute path because zsh has a builtin by that name.

## One-time setup: signing identity

Run once after cloning:

    make signing-identity

Without it, `make app` fails with an xcodebuild error beginning `No certificate matching 'LowTalker Dev' found`. `make cli` stops too, with codesign's `LowTalker Dev: no identity found`: it signs with the identity, which `scripts/signing-identity` reads off `project.yml`, so the app and the CLI cannot end up signed by different certificates.

### Why a certificate

macOS keys the Microphone grant to the app's code signature, its "designated requirement". For an ad-hoc-signed build that requirement is the hash of the specific binary, so every rebuild is a new app as far as macOS is concerned and the grant is gone. For a certificate-signed build the requirement names the certificate instead, and it survives rebuilds.

### What the command does

`make signing-identity` creates a self-signed code-signing certificate named `LowTalker Dev`, valid for ten years, and imports it into the login keychain pre-authorized for `codesign`. It shows no dialogs and asks for no password. It sets no trust settings on purpose; `codesign` does not need them. Running it a second time refuses with an error, since two certificates with the same name would make builds ambiguous.

The name lives in one place: `project.yml` sets `CODE_SIGN_IDENTITY` to `LowTalker Dev`, and the Makefile reads it from there.

To confirm a build is signed with it:

    codesign -dvvv --requirements - "DerivedData/Build/Products/Release/LowTalker Dev.app"

The `designated =>` line should name `certificate leaf = H"..."`, which is stable across builds. An ad-hoc build shows `cdhash H"..."` instead, and that hash changes every build.

### Hardened Runtime and entitlements

Both installations, and everything embedded in each - the CLI and the input method bundle - are built with Hardened Runtime, which notarization requires: `project.yml` sets `ENABLE_HARDENED_RUNTIME`. `codesign -dv` on either bundle, on its `Contents/Helpers/lowtalker`, or on its input method bundle under `Contents/Library/InputMethods` shows `flags=0x10000(runtime)`.

The runtime holds a program to a set of restrictions, and each exception is an entitlement. The app carries one, `com.apple.security.device.audio-input`, declared under `entitlements` in `project.yml`; xcodegen writes the plist from there into `App/Generated/`, which is ignored. Built with the runtime on and no entitlements, tccd logged `Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input but it is missing`. A Mac that already granted the microphone kept hearing. A Mac that never granted it would never be asked, and the app would hear nothing. Nothing else failed. Measured on 2026-09-16 on this Mac, both installations were built that way, and each transcribed "Hello world, this is Low Talker." from a fixture played at the microphone during a held chord.

An entitlement goes in only with the failure that needed it, written in the comment beside it in `project.yml`.

Both installations are signed without `get-task-allow`, which Xcode would otherwise add to a build meant for debugging, and a hardened process without it refuses a debugger: `lldb` and Instruments cannot attach to either copy. Read the unified log instead, as the sections below do. Every signature also carries a secure timestamp, which `codesign` fetches from Apple's timestamp server, so a build with no network fails to sign.

After a build that changes only how the embedded CLI is signed, rebuild the bundles from scratch (`rm -rf "DerivedData/Build/Products/Release/LowTalker Dev.app" DerivedData/Build/Products/Release/LowTalker.app`, then `make app` and `make release`): Xcode's copy phase does not see a re-signed tool as changed, and keeps embedding the old one (low-build-mmp).

A checkout that built before the two copies shared one configuration still has a `DerivedData/Build/Products/Debug/` with a `LowTalker Dev.app` in it, under the same bundle identifier as the one `make app` now builds, and LaunchServices may answer a lookup by that identifier with the stale one. Remove it once: `rm -rf DerivedData/Build/Products/Debug`.

### Signing for release

    NOTARY_PROFILE=<profile> scripts/release dist ~/Library/Application\ Support/low-talker/hub   # dist/LowTalker.dmg

`scripts/release` is the whole release, three scripts run in order, each of which also runs alone:

    scripts/sign-release dist ~/Library/Application\ Support/low-talker/hub   # dist/LowTalker.app, Developer ID signed
    NOTARY_PROFILE=<profile> scripts/notarize dist/LowTalker.app                # notarized and stapled
    scripts/make-dmg dist/LowTalker.app dist                                    # dist/LowTalker.dmg, signed
    NOTARY_PROFILE=<profile> scripts/notarize dist/LowTalker.dmg                # notarized and stapled

The app and the disk image are each signed, notarized and stapled. Gatekeeper judges the image when it is mounted and the app again when it is first run. On a Mac with no network, a stapled ticket is the only way it can reach a verdict on either, unless that Mac has already learned the ticket. So the app is stapled before it goes into the image, which cannot change once it is signed, and the image is stapled after. `scripts/release` asks the profile to answer before the build starts, so a missing credential stops it in seconds rather than minutes. Every bundle carries the version `project.yml` sets, `MARKETING_VERSION` and a build number, `CURRENT_PROJECT_VERSION`, which is raised by hand before each release. The Nth release is build N, so `scripts/release` refuses a built app whose build number is no higher than the number of release tags already on origin (`v0.1.0-alpha.3`, the third, was build 3), before anything is sent to be notarized.

An offline check on the Mac that notarized a release cannot show that the staple works, because that Mac already knows the ticket. On 2026-09-23 a throwaway app was notarized and stapled, packed with `scripts/make-dmg`, and the image notarized. One copy was stapled and one was not, and both were given a browser's quarantine. Then a pf anchor blocked every outbound connection except DNS and api.anthropic.com, which the agent running the test needed, and api.apple-cloudkit.com was confirmed unreachable. `spctl` accepted both copies as `source=Notarized Developer ID`, the unstapled one included, and it still did after `syspolicyd` was restarted. Notarizing and stapling here had taught this Mac the ticket, and the two copies share one code signature, so it covered both. The v0.1.0-alpha.3 release behaved the same way under the same block: `syspolicyd`'s ticket lookup timed out, the image mounted, and the app launched from `/Volumes/LowTalker` with no prompt. That shows only what this Mac already knew. `xcrun stapler validate` is not an offline check either: it asks CloudKit for the ticket and fails with error 68 when it cannot reach it, even on a stapled file. The staple is only proved by a Mac that has never looked the ticket up, opening the image with the network off.

That Mac was studious.local, an M1 Max Mac Studio on macOS 15.0.1 that had never run low-talker, on 2026-09-23. The same three images were copied to it and quarantined. A pf anchor there blocked every outbound connection except to the Mac driving the test over SSH, and api.apple-cloudkit.com and 1.1.1.1 were confirmed unreachable. With the network off, `spctl` rejected the unstapled probe image as `source=Unnotarized Developer ID` and accepted the stapled one, so the check tells a staple from no staple. It accepted the v0.1.0-alpha.3 image as `source=Notarized Developer ID`, and `syspolicyd`'s lookups at CloudKit timed out throughout. The image mounted in 2 s with no prompt. Opening the app out of it drew the confirmation macOS shows the first time any downloaded app opens: "“LowTalker” is an app downloaded from the Internet. Are you sure you want to open it?", adding "Apple checked it for malicious software and none was detected", with Open, Show Disk Image and Cancel. No developer can remove that dialog. It is not the "cannot be verified" warning, which is what a missing ticket produces. After Open, the app ran from `/Volumes/LowTalker`, and its first request was for the microphone.

`scripts/sign-release` runs `make release` with `SIGNING_IDENTITY` set to the `Developer ID Application` certificate for team 6R988MUU27, and that identity is the only thing it changes about the build: `project.yml` has one build configuration, and it signs every build, the development copy included, with Hardened Runtime and a secure timestamp and without `get-task-allow`, so a bundle built by `make app` differs from a shipped one only in its names and its certificate. The bundle carries the default model ("The model store" above), taken from the source the second argument names, as `model download --from` reads it, or from huggingface.co when there is none, and the script requires `model status` to find it whole inside the built bundle. The build goes into a derived-data directory made for the run and deleted after it, so a tool re-signed without changes to its code is always embedded again (low-build-mmp). It then checks the app, the carried CLI `Contents/Helpers/lowtalker`, and every input method bundle under `Contents/Library/InputMethods` for what the notary service refuses: a signature that is not the team's Developer ID, no Hardened Runtime, no secure timestamp, or `get-task-allow`. The first of those it finds stops it with the binary named. An app carrying no input method bundle fails there too, rather than passing a check that ran zero times. A bundle signed with the development identity fails the first. The Developer ID certificate lives in the login keychain, and `codesign` signs with it without a prompt.

`scripts/notarize` takes the signed app or a disk image, submits it with `notarytool` under the keychain profile `NOTARY_PROFILE` names, waits, and prints the notary log when the answer is anything but Accepted. It then staples the ticket and requires Gatekeeper to assess the result as `source=Notarized Developer ID`. The profile is made once per Mac with `xcrun notarytool store-credentials <profile>`, from an Apple ID with an app-specific password or from an App Store Connect API key. This Mac's profile is `lowtalker-notary`, and submissions under it have been Accepted since 2026-09-16. A missing profile, a profile that does not exist, and a path that is neither an `.app` nor a `.dmg` each stop the script with a message.

`scripts/make-dmg` puts the app beside a link to `/Applications` in an LZFSE-compressed image, and signs the image with the certificate that signed the app, read off the app's own signature. It refuses an app that is not signed with a Developer ID certificate, checks the image for that signature and a secure timestamp, and mounts the image to verify the app as a person will find it. The dev-signed app is refused by name. Measured on 2026-09-16 with the release carrying the default model, the image took 21 s to make and is 482,836,863 bytes. Before notarization, `spctl --assess --type open --context context:primary-signature` rejects it with `source=Unnotarized Developer ID`; after it, the same command accepts the image as `source=Notarized Developer ID`.

`syspolicy_check notary-submission` is no help on this Mac. It reports `Internal Xprotect Error` for this app, for the dev-signed build, and for a one-line Swift app signed the same way, while iTerm and Karabiner-Elements pass. So the notary service's answer is the one that counts.

### Starting over

To recreate the certificate, delete `LowTalker Dev` and its private key in Keychain Access (login keychain, My Certificates), then run `make signing-identity` again. The new certificate is a new signature, so re-grant the app's permissions in System Settings.

This certificate is for local development only. Nobody trusts it and it cannot distribute the app; release builds sign with Developer ID instead, as "Signing for release" above describes.
