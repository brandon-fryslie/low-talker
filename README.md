# LowTalker

Native macOS push-to-talk dictation, as a menu-bar app. What it is and why it exists is in [PROJECT.md](PROJECT.md); this file covers building it.

## Two installations

LowTalker installs twice and both copies run at the same time. The release copy is the one that runs all day, launched at login, held on Right Option. The development copy is built from the working tree and runs beside it, on Right Option **and Right Command together** — hold Right Command first, because Right Option alone completes the release chord and that press then owns the hold.

They are one program, not two. What separates them is four names macOS keys an installation by — the bundle identifier, the Mach service, the launchd label, and the config file — and every one of them is decided in `Sources/Flavors/Flavor.swift`. Nothing else differs; the model store is deliberately shared, the weights being gigabytes and identical.

The cost of the second copy is paid in grants: it needs its own Microphone, Accessibility and Input Monitoring approvals, its own Login Items approval, and one cold Neural Engine model load, that cache being keyed by signing identifier.

## Building

You need Xcode 16 or later plus `xcodegen` and `jq`, both from Homebrew.

- `make app` generates the Xcode project from `project.yml` with XcodeGen and builds the **development** copy, `LowTalker Dev.app`, into `DerivedData/`, printing the path.
- `make run` builds and launches it.
- `make release` builds the release copy, `LowTalker.app`, into the same place.
- `make install` builds the release copy and puts it in `/Applications`, which is where it is launched from at login and so the path its approvals are recorded against. The development copy is deliberately not installed: it runs from `DerivedData/`, and it is not a login item.
- `make cli` builds the command-line tool into `.build/debug/lowtalker` and signs it; "Trying the engine" below uses it.
- `make helper` builds the root keyboard helper into `.build/debug/lowtalker-keyboardd` and signs it; "The keyboard helper" below says what it is.
- `make test` runs `xcodegen generate` and `swift build`, then `make check-docs`, `scripts/virtual-hid-driver-test`, `swift test`, and finally `make cli helper`. Generating comes first because the suite reads the project and the plists XcodeGen writes rather than generating them itself, so a bare `swift test` on a fresh clone fails those cases; the build comes next because everything after it needs the CLI; the signing comes last because every link ad-hoc signs the product and drops the dev identity the helper admits callers by.
- `make clean` removes the generated project, `DerivedData/`, and `.build/`.

CI runs `make signing-identity`, `make test`, and `make app` on a macos-15 runner for every pull request to master and every push to master; the workflow is `.github/workflows/ci.yml`.

Before the first `make app`, `make cli`, or `make helper`, do the one-time setup below.

## Trying the engine

    make cli
    .build/debug/lowtalker transcribe Tests/LowTalkerCoreTests/Fixtures/hello-16k-mono.wav

prints the transcript, then one line per word with its start, end, and confidence. Pass `--model` with another folder name from the whisperkit-coreml repo to try a different one. `--vocabulary` names a term the speaker is expected to say, spelled as it should be written; repeat it for several. The engine is told the vocabulary ahead of the audio, the way a mode will tell it the user's names or the running apps, and "The latency harness" below shows what that does.

`make cli` is `swift build` plus a re-signing step; the section below says why it matters.

### The model store

The app and the CLI share one model directory, `~/Library/Application Support/low-talker/hub`, laid out the way the Hugging Face hub lays out its cache. A model is two parts: its weights, under `models/argmaxinc/whisperkit-coreml/<variant>`, and the tokenizer they decode with, under `models/openai/whisper-<size>` and shared by every model of that Whisper size. The first `transcribe`, or the first launch of an app that carries no model, installs the default Whisper model (about 632 MB) into it and records a manifest of each part's files and their sizes, `installed/<model>.json` for the weights and `installed/tokenizer/<model>.json` for the tokenizer. Every launch after that checks both manifests against the files and loads straight from disk, so the app works offline once the model is installed.

    .build/debug/lowtalker model status      # where the model stands; exits 1 unless installed
    .build/debug/lowtalker model download    # install it, or finish an install that stopped

A part whose manifest is missing or no longer verifies is taken again, and a part that verifies is left alone. A download that stopped part way leaves no manifest, so the model reads as missing and the next download resumes it: the hub client skips every file already on disk that its own sidecar marks as downloaded. A listed file that is no longer there as recorded reads as damaged, and `model download` repairs it by deleting the files the manifest rejects before fetching the part again; the hub client never hashes a file it finds on disk, so a truncated file would otherwise pass. A manifest that no longer parses is not repaired: `model download` stops and says to delete it and the folder that part lives in, and the next download starts fresh. A store written before the tokenizer had a manifest reads as damaged, "the tokenizer is not installed", and `model download` from the default source records the tokenizer already on disk without touching the network; from a published base it downloads the archive for the tokenizer in it. The app and the CLI may both start an install; the second waits for the first. Pass `--models-dir` to any of these commands, or to `transcribe`, `dictate` and `bench`, to use a different directory.

By default a missing part comes from huggingface.co. `--from`, on `model download`, `transcribe`, `dictate` and `bench`, names another source, so a network that blocks that host still has a way to a model:

    .build/debug/lowtalker model pack --to dist                              # dist/<model>.zip, from this store
    .build/debug/lowtalker model download --from https://example.com/models/  # fetches <base>/<model>.zip
    .build/debug/lowtalker model download --from /Volumes/LowTalker/hub       # copies from another store

`model pack` writes the archive a published base serves: a store holding that one model, both parts and their manifests and nothing a hub client left beside them. A `--from` beginning `http://` or `https://` is such a base; the archive is downloaded, unzipped beside the store, and read as a store. Anything else is a directory holding a store, and only the files its manifests list are copied, after those manifests verify there. A base that answers anything but 200, or a store that does not hold the part whole, is an error naming the URL or the part. Measured on 2026-09-16, the default model packs to 477,836,162 bytes, and a store with outbound network denied except to localhost installed it from a local base, reported it installed, and transcribed with it.

A release carries its model and loads it in place. `scripts/sign-release` installs the default model into a store of its own and builds that store into the bundle at `Contents/Resources/model-store`, where the code signature seals it with the rest of the app. The app loads the model straight from there, read-only: it writes no model data outside the bundle and never creates `low-talker/hub` for it, so a first launch with the network off needs nothing it did not ship with, deleting the app leaves nothing behind, and `codesign --verify` still passes. It rides inside the bundle rather than beside the app on the disk image, because dragging the app to Applications leaves behind anything that sat beside it. A bundle with no store, which is every development build, downloads from huggingface.co into Application Support as before. A bundle whose store does not hold the model whole stops the load with the reason, and downloads nothing. Measured on 2026-09-16, the release bundle is 625 MB. Loading a carried store whose files are unwritable — the store the code signature seals is read-only on disk — installs nothing and takes no lock: the load and its first transcription both succeed straight off the read-only store. A carried weight file changed by one byte fails `codesign --verify`. What loading in place costs after an update is "Load times and the Neural Engine cache" below.

### Load times and the Neural Engine cache

Loading the model means Core ML compiling it for this Mac's Neural Engine, which takes minutes for the default model. macOS caches the result, keyed by the model's path, the files that sit there, and the **code-signing identifier** of the process that loaded it, and evicts the cache after an OS update. Replacing the files at a path it had already compiled — which is what an app update does to a model carried in the bundle — misses the cache as surely as moving them. Measured on an M2 Max with the default model; the smaller models in the table under "The latency harness" compile and load faster:

| Situation | Load |
|---|---|
| First load of a model, after an OS update, or after the store moved or its files were replaced | 1.5 to 4.5 minutes |
| Same signing identifier, same files, model already compiled | 1.5 to 7 seconds |
| A binary with a new signing identifier | 2 to 4 minutes again |

`swift build` links a fresh identifier into every binary it produces, so a plain `swift run` pays the full compile after every rebuild. `make cli` re-signs the built binary with the fixed identifier `lowtalker`, which keeps the cache warm across rebuilds, and with the dev identity, for the keyboard helper's sake ("The keyboard helper" below). The app's identifier is its bundle id, set by its certificate signature, so `make app` builds keep the cache warm on their own.

A release that carries its model pays this compile on its first launch — a model just shipped has never been compiled here — and loading it in place pays it again after every update, because replacing the app rewrites the model files at their path and the cache does not follow them. This is the cost the copy had been hiding: a model copied into Application Support outlived an app update untouched, so an update relaunched warm; a model loaded from the bundle is replaced along with the bundle, so the first launch after each update is cold again. Measured on 2026-09-16 on an M2 Max, loading the default model from a fixed path with the CLI: 171 s cold the first time, 2.1 s once the cache was warm, and 180 s again after the model files at that path were replaced with an identical copy — the update. While the model is not yet ready, the menu bar icon is an hourglass, described to Accessibility as "LowTalker: preparing the model", and the menu's model line is the one the log records, "loading model, minutes the first time on this Mac, 0 s so far" while it loads and "ready (large-v3-v20240930_turbo_632MB) after ..." once it is resident, counted from launch, with a second line meanwhile saying a press made now is heard once the model is ready. A load that fails draws a warning triangle. A Mac that has never run low-talker also runs Gatekeeper's first check of the notarized bundle. On an Apple M5 Max running macOS Tahoe that had never run low-talker, the notarized release (v0.1.0-alpha.2) launched with no Gatekeeper prompt and was ready 2 min 4 s after launch, the network on — quicker than the M2 Max here, on a newer Neural Engine. The virtual-keyboard helper has been approved and run from the notarized build on this Mac ("Signing for release" below). Mounting the image with the network off and launching out of it is still to be seen (low-dist-idg.vbl).

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

For `mic` and `mic request` the exit status is 0 when access is granted and 1 otherwise; `watch` runs until interrupted. macOS charges a terminal command's microphone use to the terminal, so these answers are the terminal's; the app asks on its own behalf the first time it launches. macOS posts no notification when the switch is flipped in System Settings, so a change is only seen by reading the status again; `watch` reads it once a second.

To see the first-launch prompt again, forget the app's decision and relaunch:

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

Each press prints `began` as the key goes down. A release after the threshold (250 ms by default) prints a line beginning `ended (hold)`; a release before it is a tap, which leaves listening on until the next press of the key prints one beginning `ended (tap)`. Each `ended` line carries `lapses`, how often macOS has switched the tap off and it was switched back on; a press during a lapse reaches the frontmost app and is not reported, and a lapse ends any press in progress. While the tap is on, the key that completes the chord never reaches the frontmost app: its down and up are swallowed. Any modifier held to make the chord — Right Command, for the development installation — is not, since it completed nothing on its way down. Pressed with another modifier already held it is a different chord and passes through, and Left Option is untouched.

Which chord that is depends on the installation, and the CLI defaults to the development one: `lowtalker hotkey` watches Right Option and Right Command together unless `--flavor release` is passed, in which case it watches Right Option alone. Every command that reaches a helper or reads a config takes the same `--flavor`, and defaults the same way, because this tree is the development copy.

The tap needs Input Monitoring and Accessibility. macOS charges a terminal command's tap to the terminal, so the command fails with `the session refused an event tap` until the terminal has both under System Settings > Privacy & Security; the app asks on its own behalf.

    .build/debug/lowtalker hotkey --heard-by clipboard   # the clipboard delivery's hotkey, needing neither

`--heard-by clipboard` watches the chord the clipboard delivery uses (see "Deliveries" below), registered as a Carbon hot key instead of read off a tap, so it needs no permission at all. Each `began` line also says how long after its own stamp the press was delivered; on this Mac that is 100 to 300 µs, which is how the hot key's clock is known to be the one the microphone's buffers are stamped on. A chord another app has already registered is refused by name.

## The config file

    make cli
    .build/debug/lowtalker config check

reads this installation's file in `~/.config/low-talker` — `config.dev.toml` for the copy built from this tree, which is what the command defaults to, and `config.toml` for the installed one under `--flavor release` — and prints what the app would run with. It starts nothing. `--path` reads some other file instead, which is how a file is checked before it is installed, and it needs `--flavor` said out loud: which installation a file is read as decides every default it does not set, and the command refuses to guess. No file at all is not an error: the app runs on the defaults, dictation on this installation's own chord with the default model. A file that exists but cannot be read, or cannot be understood, is an error and is never quietly replaced by the defaults, since a config the user wrote and the app silently ignored is worse than one it refuses.

The file names a `model`, a model folder name such as `base.en`, an optional `[microphone]` table saying what the device does between presses, and an array of `[[modes]]` tables. Each mode takes a `name`, a `chord`, an optional `vocabulary` of terms, and an optional `routes`.

    model = "base.en"

    [[modes]]
    name = "dictation"
    chord = { modifiers = ["rightOption"] }
    routes = [{ when = "always", then = { insert = "focus" } }]

    [[modes]]
    name = "safari"
    chord = { modifiers = ["leftCommand", "leftShift"], key = 1 }
    vocabulary = ["Kubernetes", "Anthropic"]
    routes = [{ when = "always", then = { insert = { app = "com.apple.Safari" } } }]

A chord is its modifiers and, where one is wanted, a key code; it needs at least one key either way. A route's `insert` is either the word `"focus"`, whatever has focus when the route fires, or a table naming an app by bundle id. A key the schema has no place for is refused rather than ignored, so a typo is told rather than silently doing nothing.

The `[microphone]` table is optional, and the file above leaves it out: with no table at all the microphone is `shut`, opened when the hotkey goes down and closed when it comes up, so the indicator in the menu bar is a record of what you dictated rather than of how long the app has been running. `at_rest = "open"` takes the trade the other way and holds the microphone from launch to quit. What that buys is the look-back, the 0.3 s of already-captured audio a press reaches back over, so a key pressed a syllable into a word still catches that word; what it costs is a lit indicator and a privacy report saying low-talker is listening on a Mac nobody has spoken to. There is no wake word yet, so `at_rest` is the only thing that holds the microphone open while nobody is dictating: it is in the file or it does not happen. The key is required once the heading is there. A `[microphone]` with nothing under it is refused as `microphone.at_rest is missing`, since a heading somebody wrote on purpose cannot be read as the default they were already getting, and any other word is refused with that word quoted back, as `microphone.at_rest: "sometimes" is not something the microphone does at rest`.

Where a fault is reported depends on how far reading got. A file that is not TOML at all names the line reading stopped on. Anything that is TOML but wrong is named by its path in the document instead, as `modes[1].routes[0].when: "sometyme" is not something a route can match on` or `modes[1].chord is missing`, and carries no line number: decoding reports the path it was at, and the TOML library exposes source positions only for a parse error, not for a document that parsed. The path counts `[[modes]]` entries from zero, the way the file writes them, so the entry it names is one the reader can count to.

A file can also parse and still say something nobody meant, and those gaps are reported too. A mode whose `routes` is an empty list claims nothing: it listens, and nothing it hears becomes anything. A mode with no `routes` key at all dictates instead. The two look almost alike in a file and mean different things, which is why the report tells them apart. A bundle id no app on this Mac answers to is reported as well; that one is checked against the machine rather than against the file, which is why it is the check command's own work and not something reading the file could ever have found.

Every heading is printed every time, so a mode with no vocabulary shows an empty `vocabulary:` rather than leaving the reader to wonder whether the key was read and ignored. On the file above, with a mode inserting into an app this Mac does not have and a mode with no routes added after it:

    /Users/you/.config/low-talker/config.dev.toml

    model: base.en
    microphone: open only while you dictate

    mode "dictation"
      chord: rightOption
      vocabulary:
      routes:
        always → insert into the focused element

    mode "safari"
      chord: leftCommand+leftShift+key 1
      vocabulary:
        Kubernetes
        Anthropic
      routes:
        always → insert into com.apple.Safari

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

prints the same report and then stays up, printing it again each time the file is saved into something different. The app reads the file once, at launch, and a save after that does not reach it; teaching it to keep up with the file as it is edited is low-app-3sp.5's work, and for now this is where a chord can be changed and seen to take effect.

A save that cannot be understood does not disturb what is running. It is named the way `check` names it, followed by the file still in force:

    refused: line 2 is not TOML: Error while parsing table header: expected ']', saw '\n'
    still running: /Users/you/.config/low-talker/config.dev.toml

Which is the whole point of reloading this way rather than re-reading the file and taking whatever comes back. A config half way through being typed is refused a hundred times over the course of an edit, and if a refusal cost the author their settings the feature would be worse than not having it. The defaults are reached by deleting the file, never by mistyping it.

Deleting the file reloads too, back to the defaults, and the report says the file is gone rather than showing the defaults as though somebody had written them. Creating a file where there was none is picked up as well, and so is creating `~/.config/low-talker/` itself: the watch is placed on the deepest directory of that path that exists, because a watch on a directory that is not there yet is deaf for the life of the process. Saves that change nothing — the file rewritten with the same bytes, or some other file in the same directory — are read and not reported, so what gets printed is the set of changes to what the app would run with, not the set of times the disk was touched.

## Acting on a route

    make cli
    .build/debug/lowtalker route --context '{"chord":{"modifiers":["rightOption"]},"press":"hold","frontmostApp":"com.apple.TextEdit","focusedElementRole":"AXTextArea"}' --text "hello from the typist" \
      | .build/debug/lowtalker act --context '{"chord":{"modifiers":["rightOption"]},"press":"hold","frontmostApp":"com.apple.TextEdit","focusedElementRole":"AXTextArea"}'

`route` prints the actions it decided as a JSON array, and `act` reads that array on stdin and performs it through the installed keyboard helper, the way the app does. The context is given to both because the router and the executor each read it and neither hands it on. `act` first raises the context's frontmost app, waiting up to 5 s for macOS to agree it is in front, and refuses the run if it will not come. Then the actions are performed in order: `insertText` is typed into the app its target names, where `focus` is the context's frontmost app and `app` names one by bundle id, which must already be in front: only the context's frontmost app is raised, and bringing a named app forward is low-commands-tpt.4's work; `sendKeys` is pressed in the context's frontmost app. Text becomes keystrokes in this process, on the console user's layout, and one key report per XPC call crosses to the helper. `click`, `scroll`, and `clickElement` are performed with the virtual mouse in the context's frontmost app: `click` presses a button at a point, `scroll` turns the wheel there, and `clickElement` finds an Accessibility element in that app by role and title and clicks the centre of its frame, which needs this process to be allowed under Accessibility.

Each performed action prints one line:

    typed 21 characters into com.apple.TextEdit, key-up to acknowledged 312 ms
    clicked left once at (242, 16.5) after 10 move reports into com.apple.TextEdit, key-up to acknowledged 92 ms

The count is the characters typed and the app is the one they went into; a `sendKeys` line reads `pressed` and the chord instead. A click's line names the button, how many times, and the point, and its move reports are how many motion reports the cursor took to get there, which is the acceleration loop's cost ("The virtual mouse", below); a `scroll` line reads `scrolled` with its vertical and horizontal counts. The time runs from the moment the actions were handed over, which stands in for the hotkey's key-up, to the helper's acknowledgement of the last report. It is the number the app has to keep under its latency target, not a claim that the text is on screen: the daemon acknowledges reports the driver can still drop, and reading the screen back is `dext type`'s measurement, below.

A list that cannot be performed whole is refused before any key goes down, so nothing is typed. `activateApp`, `openURL`, `runShortcut`, and `pipe` are refused by name, because neither the keyboard nor the mouse can perform them, and a `click` of zero or more than three times, or a `scroll` beyond 1000 counts on an axis, is refused when the list is decoded. A chord that would press the hotkey is refused, because the keyboard is hardware to macOS and the app's own tap would take the press. Text the layout cannot type is refused whole, not typed up to the first character no key can reach. An action that stops part way, because focus moved or the helper went quiet, is reported with how much of it landed and with the actions performed before it, since none of that can be taken back. A click that stops part way releases every button on the way out and, if that release fails too, says a button may be left held. Ctrl-C stops the run and releases every key before the command exits; a release that fails is reported, so a key that may be left held is named.

It needs the helper installed (`scripts/keyboard-helper install`, under "The keyboard helper" below) and, like `dext type --through helper`, no sudo. Typing needs no Accessibility: which app is in front is read from the workspace, and the cursor's position, which the mouse reads back after every move, is readable without permission. `clickElement` is the one action that needs it, because it searches the app's Accessibility tree.

## Typing from a script

    make cli
    .build/debug/lowtalker type --into com.apple.TextEdit "hello from a script"
    .build/debug/lowtalker keys --into com.apple.TextEdit leftCommand+s
    .build/debug/lowtalker keys leftShift+leftCommand+left delete    # into whatever is in front

`type` types text and `keys` presses chords, through the same executor `act` and dictation use: the app is raised first, every key is refused once it leaves the front, and each command prints the executor's line for what it did. `--into` names the app by bundle id; without it the target is the app in front when the command starts, which from a terminal is the terminal itself. `--flavor` picks the installation's helper, as for `act`. Text that starts with `-` would be read as an option, so it follows `--`: `lowtalker type -- "$text"` types any text.

A chord is modifier names and one key joined by `+`. Modifiers are the config file's words (`leftCommand`, `rightOption`, ...). The key is a name (`return`, `escape`, `left`, `f5`, ...), the character your keyboard layout types with that key and nothing held (`s`, `/`), or `key 0x24`, the spelling the executor prints, so any chord a report names can be passed back. `keys` takes several chords and presses them in order, having proven every one pressable first; `lowtalker keys --help` lists every key name.

The exit code says what went wrong, so a script can act on it without reading stderr, and `act` exits the same way: 3 when the text or a chord cannot be typed here and nothing was typed, 4 when the helper cannot be reached because this installation's helper is not the one answering, 5 when the helper cannot be reached because the driver extension is not activated. Anything else is 1, with the account on stderr, and a misspelled chord is a usage error, 64. The helper is tried before anything is read about it: only when it cannot be reached are the driver and the helper read, and the unmet row is printed with its step, the same row and step `lowtalker onboard` prints.

`scripts/live-type-check` types into TextEdit and Terminal with these commands, presses Return with `keys`, checks that text the layout cannot type exits 3 and leaves the document unchanged, and compares the pasteboard before and after. It reads back through the probe `scripts/live-paste-check` uses, under the same conditions: an unlocked screen and a terminal with Accessibility.

## Deliveries

The app gives you what you dictate one of two ways, and asks which the first time an installation runs. It is called the delivery and not the input method because macOS has an input method of its own — a text input source, the way Pinyin or Kotoeri is one — and one word could not mean both here.

- **Clipboard.** Press Control+Shift+D (Control+Shift+Command+D for the development copy) to start listening and again to stop, or hold it while you speak, then paste with ⌘V. The hotkey is a registered hot key and the words go on the clipboard, replacing what was there, so nothing is installed and nothing asks for an administrator. The menu-bar icon turns into a clipboard when words are waiting, and back into a microphone at the next press. A route that needs the keyboard or the mouse, anything beyond text at the focus, is refused by name.
- **Virtual keyboard.** Hold Right Option (Right Command, then Right Option, for the development copy) while you speak, and the words are typed where you are. This is the driver extension and the root helper described under "The virtual keyboard driver", and the approvals under "What is left to set up".

The status menu lists both under "Delivery" with the current one checked, and choosing the other takes effect at once: a press still open is ended, sessions in flight finish, and the new delivery's hotkey comes up. Choosing the virtual keyboard registers the helper, and when the driver, the helper or Keyboard Setup Assistant still needs something, an alert lists the steps. On the clipboard the helper is never registered and the onboarding rows are not read. The choice is kept per installation in its defaults, under `inputMethod` — the spelling from before the rename, kept because the word on disk is every installed copy's stored answer; `defaults delete ai.promptctl.low-talker.dev inputMethod` makes the development copy ask again at its next launch. The app logs `delivery: asked, answered clipboard` or `delivery: remembered virtualKeyboard` at launch.

### Insert Dictation, a Service that needs no grant

The clipboard delivery leaves the words for you to paste, and a macOS **Service** lets one shortcut both end the dictation and put those words at your cursor, still without any grant the way ⌘V would need. The app declares a Service, "Insert LowTalker Dictation" ("Insert LowTalker Dev Dictation" for the development copy), under `NSServices` in `project.yml`; xcodegen writes it into the bundle's `Info.plist`, where Xcode merges it with the keys it synthesises. Its default shortcut is Command+Shift+2 for the release copy and Command+Shift+1 for the development one — the `serviceKey` `@` and `!` on a US layout — and you can rebind it under System Settings > Keyboard > Keyboard Shortcuts > Services > Text. A Service's shortcut wins only where the frontmost app has not bound the same keys itself.

When the app that is in front invokes the Service, it — not low-talker — inserts the returned text at its own cursor, so no key is posted and low-talker never reaches into it. The handler hands back the words of the last completed dictation and drives nothing: you end your own dictation, releasing a hold or tapping a second time, and the words land the moment that session is heard — the same moment they reach the clipboard and the icon becomes one. So the Service is a read, not a wait: it never ends a listening whose words are not yet transcribed, and never blocks the main actor the transcription runs on. With nothing ready it refuses with a reason rather than inserting an empty or stale string, and because `began` clears the held words at the next press, a dictation in flight refuses until it completes rather than serving the one before it. Under the virtual keyboard a session types rather than copies, so nothing is left for the Service and it has nothing to insert — which is right, those words are already in the app.

Verified on this Mac with the development copy: on the clipboard, a hold of Control+Shift+Command+D over the fixture `say/greeting` put "Hello world, this is Low Talker." on the clipboard, and `NSPerformService("Insert LowTalker Dev Dictation")` then returned it on the pasteboard it was handed in a few milliseconds, the log reading `insert dictation: returned 33 characters`; a freshly launched copy with no dictation refused the call, so the caller inserted nothing. Whether a bound shortcut reaches a real cursor is each app's to honour: iTerm2 and the native text apps carry text Services, while many Chromium and Electron apps carry none.

Verified on this Mac with the development copy: on the clipboard, a four-word utterance spoken during a held chord (then Control+Option+Command+D, since moved off VoiceOver's modifier) was on the pasteboard 698 ms after key-up, with no helper registration logged; `lowtalker hotkey --heard-by clipboard` heard a hold and a pair of taps of Control+Shift+Command+D; switched to the virtual keyboard from the menu, the next utterance was typed into TextEdit 693 ms after key-up; and with the stored choice deleted, the next launch asked, and logged the answer. The alert that lists missing steps was not seen, since this Mac is missing none.

## Dictation

The milestone 1 loop is closed: hold the hotkey, speak, release, and what was said is typed into the app in front. The app runs it, and so does the CLI:

    make cli
    scripts/keyboard-helper install
    .build/debug/lowtalker dictate    # hold the hotkey, speak, release, until interrupted

The model is loaded before the tap goes up, so `ready: hold rightCommand+rightOption to dictate` on stdout — this installation's own chord, the development one by default — means the next press will type. Key-down marks where the utterance begins on the audio ring and reads which app is in front, and does nothing else, because it runs inside the tap's callback where a slow handler is what makes macOS switch the tap off; key-up ends the mark, and the clip is heard, routed, and typed off that thread. Each press prints one line for the session, which is how many words were heard, how long after key-up, how many actions went into which app, and then the text itself, followed by the executor's line for every action performed, the `typed 21 characters into com.apple.TextEdit, key-up to acknowledged 312 ms` shape from `act` above. Sessions are heard and typed on one serial queue, so two presses in quick succession type in the order they were spoken however long the engine takes on either. Like `act`, this needs the helper installed and no sudo, and macOS charges a terminal command's tap and microphone to the terminal, so it runs under the terminal's own Input Monitoring, Accessibility and microphone grants: the loop can be proven on a Mac before the app has grants of its own.

The app wires the same loop to the real microphone, the WhisperKit engine and the root keyboard helper, and writes each session to the unified log under the `dictation` category rather than to stdout. On this Mac it launched, loaded `large-v3-v20240930_turbo_632MB` and armed the hotkey, the model ready about 2.7 seconds after launch; two utterances spoken at the microphone were transcribed and typed into TextEdit, 26 characters and 24 characters, 649 ms and 668 ms after key-up. A separate run played a recorded fixture through the speakers for the microphone to hear and typed "Hello world, this is Low Talker." into TextEdit. Both times fall in the range the batch column of the table under "The latency harness" shows for the default model, and both are more than twice the 300 ms the loop is aiming at; getting under that is the encoder's problem, not this loop's.

The loop is its own module, `Sources/Dictation`, and the microphone, engine, router, executor, keyboard layout, frontmost-app reader and the reporter that hears the outcome are values it is given, so the whole of it runs under `swift test` against a fake of each. What legitimately differs between the surfaces crosses one boundary rather than being spelled three times: the app, `lowtalker act` and `lowtalker dictate` all build their executor through `Executor.guarding`, so the guard that refuses a keystroke once the operator has interrupted or the target app has left the front gives one answer in all three.

## Paste

Paste is a CLI command, kept as it stands, and not the app's inserter. That is the keyboard helper, which the app drives today through the same executor `lowtalker act` and `lowtalker dictate` above build.

    swift run lowtalker paste "hello there"            # paste into the frontmost app now
    swift run lowtalker paste "hello there" --delay 3  # three seconds to bring the receiving app forward

The text goes on the pasteboard and the frontmost app is asked to paste through Accessibility: its own Paste menu item, the one bound to Cmd+V, is pressed, and the prior pasteboard contents go back once the app has run it, every item and every type, images included. A posted Cmd+V says nothing about when the app acts on it, and a clipboard manager pulling the pasteboard is indistinguishable from the paste, so neither serves as the signal. No wait is invented: Accessibility gives up on an app that does not answer after its own messaging timeout, 1.5 s by default, and the pasteboard goes back then. The line printed names the app and says whether the pasteboard was `restored`; when something else takes the pasteboard during the paste, that is left in place and the line says so. With no app frontmost, as at the lock screen, there is nothing to ask and the command says so. An app with no Cmd+V menu item cannot be pasted into this way; the command says so and names it. An app whose Paste item is disabled is not pressed either, since a press on a disabled item does nothing: apps validate that item on a one-second clock of their own, so the command gives a reading taken before the text went on the pasteboard one period to change before it says the item is disabled. An app that takes the press and then stops answering leaves the paste unknown, and the command says so rather than that it landed or did not: retrying may paste twice. The item carries nspasteboard.org's transient marker, so clipboard managers that honor it do not keep the dictated text.

Pressing another app's menu item needs Accessibility, charged to the terminal for this command; without it the command prints `Accessibility is off for the calling process; grant it in System Settings > Privacy & Security > Accessibility`.

## Insert

Insert is the other hand-held delivery, and it needs no grant at all. It asks the input method to put text at the cursor through the text input system, the way a Japanese or Chinese input method commits a candidate, so nothing is posted as a key and the pasteboard is never touched. The LowTalker input source has to be selected for it, from the Input menu or System Settings; the input method process launches on demand.

    swift run lowtalker insert "hello there"            # insert at the cursor now
    swift run lowtalker insert "hello there" --delay 3  # three seconds to bring the receiving app forward
    swift run lowtalker insert "hello there" --timeout 2  # how long to wait for the input method's answer

The line printed says either how many characters the client in front accepted or, by name, why it refused: no client has focus, or the cursor is in an app that is not in front. A transport that could not carry the question at all is an error rather than an answer, and it says which failure it was, because a request the input method never took means the words did not land while an answer that never came back means they may have.

What `inserted` claims is that the client belonging to the app in front accepted the commit, not that a person saw the words - the text input system offers no delivery report. The Finder's desktop, in particular, presents a full text client that accepts text into a buffer nobody can see.

`scripts/live-paste-check` pastes into TextEdit and Terminal, checks what landed (the file TextEdit writes when its window is closed, the text Terminal echoes, read through Accessibility), and compares the pasteboard before and after. It needs an unlocked screen and uses no AppleScript, because an Automation prompt nobody answers becomes a denial.

## The virtual keyboard driver

LowTalker types by driving a virtual keyboard macOS treats as real hardware: the driver extension `Karabiner-DriverKit-VirtualHIDDevice`, a public-domain pqrs-org package that ships its own installer. Karabiner-Elements is a separate, much larger application by the same author; this project uses only the driver package and never installs or requires it.

`scripts/virtual-hid-driver` does the work, in six verbs:

    scripts/virtual-hid-driver state                 # the machine's driver state
    scripts/virtual-hid-driver expect <verdict>      # assert that state
    scripts/virtual-hid-driver install [package]     # download or take a carried copy, verify, install, activate
    scripts/virtual-hid-driver fetch <directory>     # download and verify the package, for a release to carry
    scripts/virtual-hid-driver check <package>       # verify a package file against the pins
    scripts/virtual-hid-driver remove                # deactivate, delete, forget receipt

`state` prints a fact table to stderr for a reader and one verdict word to stdout, so `$(scripts/virtual-hid-driver state)` is exactly the verdict. The verdicts are `absent`, `installed-inactive`, `awaiting-approval`, `disabled`, `enabled`, `running`, `pending-reboot`, `residue`, and `unknown`. `enabled` means macOS has the extension switched on; `running` means that and the driver has published its node in the IORegistry. `running` is the fully working state.

The script installs and removes; it no longer reads. Where the driver stands is read by `lowtalker driver`, which the script calls for every one of those words:

    lowtalker driver state         # the readings to stderr, one verdict to stdout
    lowtalker driver registration  # how macOS has the extension registered, as one word
    lowtalker driver receipt <id>  # one installer receipt's version, or nothing
    lowtalker driver pins          # every constant this program holds about the driver

The probe moved out of the script because the menu-bar app has to reach the same answer in the same words, and an app in `/Applications` cannot run a script out of this repo. A second probe written to give it those words would be two clocks. So `scripts/virtual-hid-driver` needs `.build/debug/lowtalker` present — run `make cli` (or `swift build`) first, and it says so by name when the build is missing. The driver's identity — bundle id, team, IORegistry node, receipt ids, and the two payload trees — is pinned in `Sources/DriverExtension`; the script and this file keep copies, and `make check-docs` reads `lowtalker driver pins` and fails when a copy has drifted.

Run it as the logged-in user, never under `sudo`; it takes sudo itself for the file steps. macOS attributes the activation request to whoever makes it, and your approval answers that request.

Two version numbers travel together and are not the same. The package is 8.4.0 and carries the Manager and Daemon helper apps; the driver extension inside it is 1.8.0, which is what `systemextensionsctl` reports. It has not moved across many package releases, so a package upgrade that leaves `systemextensionsctl` still reading 1.8.0 has not failed. The script is authoritative for both numbers, and pins the package's SHA-256 checksum besides: nothing in Swift downloads anything, so what to fetch stays where the fetching is. This file quotes the versions, not the checksum, and `make check-docs` fails when a number quoted here disagrees with the script.

### The VirtualKeyboard module

`Sources/VirtualKeyboard` owns everything about the device and nothing about low-talker. It does not link LowTalkerCore, so it leaves for its own package by a move rather than by an untangling.

It is a client of pqrs's daemon, not of the driver. Opening the driver extension's user client requires `com.apple.developer.driverkit.userclient-access`, which Apple grants per application identifier and which only `Karabiner-VirtualHIDDevice-Daemon` holds; root does not help, and no signing work changes it. So the module speaks the daemon's Unix domain stream socket, whose directory is mode 0700 owned by root — **the calling process must be root**, which is stated once in the type and never re-checked inland.

It is spoken to in the device's vocabulary: a HID usage goes down, a usage comes up, and modifiers are usages like any other key. The device holds the set of keys that are down and derives every report from that set, so a caller never composes one. That is not tidiness — a report a caller can compose is a report that can disagree with what the device is holding, and that disagreement has exactly one shape: a key the driver believes is down that nobody remembers pressing, which macOS then repeats. For the same reason the bit a modifier sets in a report is computed from its usage rather than kept beside it: the eight modifier usages run in the same order as their eight bits, so the bit is the usage seen another way and the two cannot drift.

`start` waits for the daemon's word that the keyboard is ready, and expect close to a second of it. That is not the hardware. The daemon asks the driver on a one-second timer, so readiness is discovered on the next tick rather than when it happened, and a caller that connects per insert pays it every time. Hold the connection open. A driver version mismatch is a hard failure wherever it arrives, because a driver built for another protocol accepts reports and then does something other than what they say.

The wire protocol is tested against a fake daemon on the other end of a `socketpair`, so the framing is proven without root and without the driver. That is what the file-descriptor initializer is for. Byte order is what goes wrong silently here — the frame length and request id are big-endian, the usages inside the report are little-endian, and the client protocol version is native — and a frame read the wrong way round is still a well-formed frame.

### Typing through it by hand

    make cli
    sudo .build/debug/lowtalker dext type com.apple.TextEdit "hello there"  # type it into TextEdit and read back what landed
    .build/debug/lowtalker dext watch                                       # print every key the session's own tap sees

`type` raises the named app, types the text through the virtual keyboard, and reads the app's text back through Accessibility to report what landed. `watch` prints every keyboard event the session's own event tap sees, with the time from the driver's stamp to the tap callback, until interrupted. `make cli` builds and signs the binary; these two are shown that way rather than with `swift run`, as the sections above are, because `type` runs under `sudo` and `sudo swift run` would build as root.

`type` needs `sudo`, and not for the driver: it cannot open the driver extension's user client at all. Opening that user client takes the entitlement `com.apple.developer.driverkit.userclient-access`, which Apple grants per application identifier and which only pqrs's own `Karabiner-VirtualHIDDevice-Daemon` holds, so root does not help. `type` is therefore a client of that daemon, over a Unix domain socket at `/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock`, whose directory is mode 0700 owned by root. That socket is what the sudo is for.

The daemon is a prerequisite, and through the device nothing starts it. The public package installs no launchd job for it, and `scripts/virtual-hid-driver state` reporting `running` describes the driver extension alone: it says nothing about whether anything can type. Through the keyboard helper (below) the helper starts it; for `sudo ... dext type` through the device, start the daemon by hand:

    sudo nohup "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon" &

`sudo launchctl list | grep pqrs` does return a job, which is confusing: that job is the driver extension itself, running as user `_driverkit` under macOS's system-extension machinery, not the daemon.

An Accessibility read is not a verdict on every app, and the reader says so rather than
guessing. Measured on this Mac: VS Code frontmost with a document open answers `kAXValue`
on its focused element with success and zero characters - the identical answer an empty
TextEdit document gives. A reader that handed both back as a string would collapse "there
is nothing on the screen" into "this app will not tell you", and it did: a run that typed
all 29 characters correctly, proven by screenshot and by saving the buffer to disk,
reported `MISMATCH: the screen holds []`. So a read answers with one of three things - the
text, an empty answer, or no value at all - and only the first is evidence. The other two
print as `nothing readable: ...` and send you to a screenshot. Slack is Electron too, so
two of the five apps in this epic's done-condition are verifiable only by picture.

Walking the tree for some other element that does carry text is not the way out, and was
measured before being rejected: VS Code's tree runs past the 2000-element search limit,
1334 of those elements answer `kAXValue` with a string and 230 are non-empty - sidebar
filenames, "No code actions available", stale error text. Matching typed text anywhere in
that would trade a false negative for false positives.

`type` takes the target app's bundle id as an argument and refuses to type into anything else. It raises the named app, waits for macOS to agree it is frontmost, and re-checks before every keystroke. If the app will not come forward, nothing is posted at all:

    com.apple.TextEdit would not come to the front, com.googlecode.iterm2 is there; nothing was typed

Once typing has begun that promise is no longer available to make. A keystroke cannot be recalled, so an app that takes the front mid-run leaves a fragment in the target, and the refusal says how long it is rather than claiming the run posted nothing:

    com.googlecode.iterm2 is frontmost, not com.apple.TextEdit. 34 of 500 characters had been posted and acknowledged before this, and the rest were not sent

That is deliberate. An earlier version typed into whatever happened to be frontmost, and once delivered its text into the operator's own terminal.

The alphabet is the keyboard layout's own. `KeyboardLayout` asks macOS what every key types bare, under Shift, under Option, and under both, and keeps the answers backwards, so a character costs whatever keys a person would press for it: `\u00e9` is Option-E and then E, a curly quote is one key under Option, and an em dash is Shift-Option-hyphen. A character no key can reach is refused by name before the daemon is touched, so a refusal never leaves a half-typed line; emoji and the scripts the layout does not carry are outside the alphabet by design, since this types a keyboard and a keyboard has the keys it has.

Which layout matters, and a privileged process cannot find out. The driver sends HID usages and macOS turns them into characters using whichever layout the console user is on, so the keys have to be computed for that layout and not another. Text Input Sources answers per process: with this Mac switched to Dvorak, the console user is told `com.apple.keylayout.Dvorak` and the same call under `sudo` is told `com.apple.keylayout.US`. Typing the US keys under Dvorak put `yd. 'gcjt xpr,b` on screen for `the quick brown`, and every check the command makes still passed, because the daemon acknowledged all of it and the screen genuinely held what had been typed. That is why text becomes keystrokes on the user's side of the privilege boundary and only keystrokes cross it. `dext type` runs wholly as root and so cannot read the console user's layout at all: it prints the layout it used on every run, and `--layout <input source id>` names one when the machine is not on root's US. Typed that way, `the quick brown fox jumps over the lazy dog` lands exactly on a machine switched to Dvorak.

The first keystroke waits up to about a second after the connection is made. That is not the hardware. pqrs's daemon polls the driver for readiness on a one-second timer, so readiness is discovered on the next tick rather than when it happens. Once the driver is ready, a character reaches the screen in roughly 10 to 35 ms. Longer text is another matter. Each report is awaited rather than fired, because reports posted back to back are lost, and a lost key-up leaves its key held for macOS to repeat: an unpaced 500-character run ends in hundreds of one shifted character. Awaiting them fixes that and is not a sleep, since the daemon answers every request, but it does not make length safe either: half of twelve 500-character runs came out wrong. Where they go is measured rather than guessed. The app's own event tap counts the keys that arrive, and on every bad run it saw fewer than the 500 the daemon had already acknowledged — as few as 469, and once a matched down and up together, so that keystroke never became an event at all. The acknowledgement is not a delivery receipt, and the loss is under it, in the driver. Nor is a short document the only way it shows: one run lost 41 key-ups and macOS repeated the keys it left held into 608 characters.

Then the rate changed and the loss went with it. Through the VirtualKeyboard module the same burst takes 320 to 370 ms where the spike's took 167 to 220, and sixteen runs of 500 characters landed all 500 — tap downs, tap ups, modifiers and document all exact, every run. The control is a 500-character run with nothing shifted, which puts exactly the reports on the wire that the spike put there: 323 ms, complete and in order. So the loss is rate-dependent, and the rate that loses is above three reports per millisecond and at or below six. That is a bound and not a characterisation — sixteen runs at one rate say where the cliff is not — and finding it is the typist's work, not the driver's.

macOS raises the Keyboard Setup Assistant the first time the virtual keyboard appears; it steals focus and asks for a physical keypress, and during the spike it swallowed a whole run's keystrokes — the text went to `com.apple.KeyboardSetupAssistant` instead of the target app. It caches its answer in `/Library/Preferences/com.apple.keyboardtype.plist`, keyed `<product>-<vendor>-<country>`, and never asks again about a device that already has an entry. Nobody types that entry any more. The keyboard helper files it, as `KeyboardTypeAnswer`, in the first moments of every start: the write wants root and the helper is root, it knows which keyboard it owns, and it is the one process that must already be running before the virtual keyboard can type at all. It is filed before the helper brings the devices up, because the assistant appears when the keyboard *enumerates*, so an answer filed after that is a race with the dialog it exists to prevent.

The file is a shared one — it held fourteen devices' answers on this Mac — so the write is a read, a merge and a write back, and a cache that cannot be parsed is refused with nothing written rather than replaced by a file holding our one entry. Our own key is what gets written, and never another device's: this cache already held `10203-5824-33` from some unrelated country-33 device, and initialising this keyboard as country 33 to collide with that entry would make the device declare something untrue about itself, and would work only until that entry was cleared. A helper that could not file the answer says so in its log and types anyway; onboarding's row stays unmet until the answer is actually on disk, so the failure is reported twice and swallowed nowhere.

`watch` runs as the logged-in user and needs the terminal's Input Monitoring and Accessibility, as `hotkey` does. It sees the synthetic keys too: the app's own tap observes the keys the app types, which is a thing anything built on this has to account for.

### The keyboard helper

`lowtalker-keyboardd` is a root launchd daemon that presses the keys, so that neither the app nor the CLI has to run as root. It is a client of pqrs's `Karabiner-VirtualHIDDevice-Daemon` over the root-only socket described above, and it serves one XPC Mach service, `ai.promptctl.low-talker.keyboardd`. The keyboard's half of the protocol is key events, never text: a key goes down, or every key is released. Text becomes keystrokes on the user's side, for the per-process layout reason above, and only keystrokes cross to the helper.

The certificate decides who may call it. At startup the helper reads the certificate off its own code signature and admits only callers signed by that certificate, checked against the connecting process's audit token; an ad hoc-signed copy of the CLI was refused. That is why `make cli` signs with the dev identity and not only the fixed identifier: the CLI has to carry the certificate that signed the helper to press a key. A helper that is itself signed ad hoc would admit no one, so it refuses to start - exiting 0 with the reason in its log, because launchd's KeepAlive restarts every other exit - and `scripts/keyboard-helper install` refuses to install one.

A client that goes away leaves nothing held. When a client's connection ends the helper releases every key that is down: a client killed 69 characters into a burst left the document unchanged 3 s later, and the helper logged every key up.

The helper looks after the daemon as well. If the pqrs daemon is not running the helper starts it, and stops it again when the helper is asked to stop. It holds one connection to the daemon open for its whole life and sends the daemon a heartbeat every 3 s: the daemon itself sends heartbeat frames every 3 s and hangs up on a client silent for 15 s, and answering its status pushes does not count. The pqrs daemon killed underneath the helper was restarted by the helper within 2 s.

XPC costs about 1 ms per character. 1400 characters landed complete through the helper.

### Two registrations, one Mach service

The same helper is registered in two ways, and only one of them can be live at a time.

The shipped app bundles the helper and a plist at `Contents/Library/LaunchDaemons/ai.promptctl.low-talker.keyboardd.plist`, label `ai.promptctl.low-talker.keyboardd`, and registers it with `SMAppService.daemon` on every launch. On the first launch of an install the menu item and the log read "Keyboard helper: waiting for approval in Login Items & Extensions", and the step printed under that line says to turn LowTalker on in System Settings > General > Login Items & Extensions, which is where the approval click happens ("What is left to set up" below). On this Mac the app-owned Background Task Management record appears in `sfltool dumpbtm` as type daemon parented to the app bundle, disposition disallowed until approved. Once approved it reads `Disposition: [enabled, allowed, not notified] (0x3)`, and launchd runs the daemon: on 2026-09-21 `launchctl print system/ai.promptctl.low-talker.keyboardd` showed it `running`, submitted by `smd`, managed by `com.apple.xpc.ServiceManagement`, with `--flavor release` among its arguments.

`scripts/keyboard-helper` is the dev and agent path, which needs no approval from anyone:

    scripts/keyboard-helper install [flavor]    # register .build/debug/lowtalker-keyboardd as a LaunchDaemon
    scripts/keyboard-helper uninstall [flavor]  # stop it and remove the job
    scripts/keyboard-helper state [flavor]      # what launchd says about the job
    scripts/keyboard-helper log [flavor]        # what the helper has said in the last ten minutes

`flavor` is `release` or `development`, and defaults to `development` — this tree is the development copy, and reaching into the installed copy's job is a thing to ask for by name.

`install` needs `make helper` to have run, refuses an ad hoc-signed helper, writes `/Library/LaunchDaemons/<label>.plist` with KeepAlive, and bootstraps it with sudo. It passes `--flavor` in `ProgramArguments`, because the binary is the same program in both installations and has no other way to know which one it serves; a helper given no flavor refuses to start and says so. `uninstall` boots out any plist job under the label, whatever its file is called, and removes this installation's plist whoever holds the label: left behind, it would load at the next boot ahead of the app. A label held by the installation's own app is named and left alone, since booting that out would take its approval record with it. Either command refuses outright when it cannot read who holds the label, rather than reading a refused `sudo` as nobody. The helper releases any keys and stops the daemon it started. `log` reads the unified log for that installation's subsystem.

Within one installation the launchd label and the Mach service carry one name — `ai.promptctl.low-talker.keyboardd` for the release copy, `ai.promptctl.low-talker.keyboardd.dev` for the development one — and the two installations share neither. Nothing is shared, which is what lets both run at once; and one name per installation is what makes a collision inside one of them loud. Two jobs under one label are refused at bootstrap: exit 5, "Bootstrap failed: Input/output error", and no job is added. So `scripts/keyboard-helper install release` on a Mac whose LowTalker.app has already registered its helper fails where it should, rather than adding a second daemon.

Both halves of that were measured. Background Task Management files jobs by label: when a dev job was installed under the app's label and the app was then launched, BTM treated the app's registration as an update of the dev record, the app's daemon was bound to the dev plist's path, launchd logged "Invalid path: Contents/MacOS/lowtalker-keyboardd" and it never spawned, and the approval was inherited instead of asked. BTM drops a record whose plist has been deleted about a minute later, on its own. The other half is two *different* labels naming one Mach service, which is what this repo used to do: measured with a probe job, the second claimant bootstraps with exit 0, runs, and simply never gets the endpoint, while launchd writes one debug line ("already exists and is owned by") that nobody reads. A helper sitting unreachable while logging that it was listening is what that cost, and it is why the label and the service are now one name per installation.

What no label governs is a helper started by hand from a terminal: it holds the service with no job for launchd to refuse. So `install` still reads back whether its job got the name and, if it did not, tears its own job down and exits 1 saying so. The app reads the same thing in the other direction, asking launchd who holds the Mach service and sharpening that with `SMAppService`'s status, the one answer only it can get. A `.build/debug/lowtalker-keyboardd` left running from a terminal beside the launchd-owned one is what an `NSCocoaErrorDomain 4099` on the app's first keystroke turned out to be, and killing the hand-launched copy is the whole of the fix, nothing having been wrong with the typing path.

### Typing through the helper by hand

    make cli
    scripts/keyboard-helper install
    .build/debug/lowtalker dext type com.apple.TextEdit "hello there" --through helper

No sudo. `--through helper` sends the keystrokes to the installed helper instead of opening the daemon socket in this process; the default, `--through device`, is the sudo path above. Because the CLI now runs as the logged-in user, the layout it reads is the console user's own, so `--layout` is not needed the way it is under sudo.

### The virtual mouse

The same driver publishes a pointing device beside the keyboard, and the same helper owns both. One connection to pqrs's daemon carries the two devices: request 3 brings the pointing device up, with no payload, status 5 says it is ready, and request 11 posts a pointing report. At startup the helper logs "the mouse is up: the daemon answered in 0.0048 seconds, ready after 1.07 seconds" beside the keyboard's matching line, and "starting; every button is up".

A pointing report is 8 bytes with no report id: 4 bytes of buttons as a little-endian 32-bit field in which button n is bit n-1, so left is 1, right is 2 and middle is 3, then x, y, vertical wheel and horizontal wheel as one signed byte each, -127 through 127. Motion is relative only; the device has no absolute position. The helper's XPC protocol gains four calls for it: a button down, 1 to 32; release every button; move by x and y; and scroll by vertical and horizontal. It refuses button 0 and 33 and above, and the one byte value -128, which the descriptor does not admit. As with keys, when a client's connection ends the helper releases every button.

Reaching a point is the client's problem, because macOS applies pointer acceleration to hardware motion: a report of 127 counts moves the cursor by whatever the acceleration curve makes of that speed, and the device is not told. A plain loop that posts the clamped remaining distance each time oscillates, overshooting at speed and then overshooting back. So the pointer estimates the gain each step, points moved over counts asked, and divides the next request by it; a report that moved nothing halves the estimate so the next ask doubles. Because the curve grows with speed and the requests shrink as the target nears, each step after the first undershoots and the loop converges from below; the exception is the floor of one count, which a remainder just over half a point can step past, and the next round's estimate takes that back. After every report it reads the cursor's real position back through `CGEvent(source: nil).location` and waits up to 50 ms for it to move. That position is global, top-left origin, in points, the same space Accessibility reports element frames in, so a frame's centre is a target with no conversion, and reading it needs no permission. A move is done when both axes are within half a point. Three reports in a row that bring the cursor no closer end the move as "would not reach", as do 64 reports. A wheel scroll goes out in reports of at most 127 per axis: 300 is 127, 127, 46.

Clicking by hand. The target is a menu bar item, chosen because opening a menu is harmless and Escape puts it back. Nothing in this runbook raises a dialog that grants anything or asks for a password: driving synthetic clicks at a real authentication prompt teaches the habit of answering one, and the reader who follows along is the person that habit costs.

    make cli
    scripts/keyboard-helper install
    osascript -e 'tell application "TextEdit" to activate'
    .build/debug/lowtalker click AXMenuBarItem Format

`click` aims at whatever is in front. It is the hands half of a pair: `lowtalker see` is
the eyes, and takes no positional arguments - only `--shot <path>`, to name where the
picture goes so a before and an after can be kept side by side.

    .build/debug/lowtalker see
    frontmost com.apple.TextEdit
    alerts 0
    focus AXTextArea holds [Hello world, this is Low Talker.]
    screenshot /var/folders/.../lowtalker-see-1788802162595.png (1691751 bytes)

`see` reports the frontmost app, how many system alerts macOS has over everything, what
the focused element is and whether it will say what it holds, and then takes a screenshot.
The picture is attempted whatever the readings above it did, and a run that cannot take one
says so on the screenshot line and exits non-zero. It is not optional because for some apps
it is the only true answer, and because a `see` before a click and a `see` after it are
then comparable pictures.

The virtual mouse refuses to press while a system alert is up - `click` and the routed
`clickElement` below alike, because the refusal lives in the mouse rather than in whichever
command started the click. An alert sits at the same screen centre every dialog does, so a
frame located in the app underneath one has somebody else's button over it, and a click at
that frame's centre would answer their prompt instead. It is asked at the press rather than
at every motion report, because a move cannot answer anybody's prompt and a press can, so
an alert that opens while the cursor is still travelling is still caught at the press. The
count is read from `com.apple.UserNotificationCenter`
through Accessibility with a half-second messaging timeout, deliberately not through
System Events, which a modal SecurityAgent dialog can leave waiting rather than answering.

The picture is of the main display: `screencapture` is run with `-m`, because without it
a Mac with two monitors gets one file per display and none at the path that was asked
for. And the process must hold Screen Recording, which a binary run from a terminal that
holds it does - TCC attributes the grant to the responsible parent - so `see` checks
rather than assumes: without it `screencapture` writes a blank picture that looks exactly
like a real one.

The same click is still reachable as a routed action, for a route that decides one:

    echo '[{"clickElement":{"role":"AXMenuBarItem","title":"Format"}}]' | .build/debug/lowtalker act --context '{"chord":{"modifiers":["rightOption"]},"press":"hold","frontmostApp":"com.apple.TextEdit","focusedElementRole":null}'

TextEdit's Format menu opens under a highlighted title, which is the click landing somewhere you can see it; Escape closes it again. `clickElement` searches the frontmost app's Accessibility tree breadth first for an element of that role and title, stopping at 2000 elements, or at a 5 s budget polled once per element which the element in hand can carry about 1.5 s past, and clicks the centre of its frame; an element with no area is refused by name. An element that will not answer does not fail the search, but it does stop a fruitless one reporting that the element is missing. The other two forms are `{"click":{"at":{"x":242,"y":16.5},"button":"left","times":1}}` and `{"scroll":{"at":{"x":100,"y":200},"vertical":-3,"horizontal":0}}`. A scroll of 0 by 0 is a bare move, which is how the loop is measured: `[{"scroll":{"at":{"x":1400,"y":800},"vertical":0,"horizontal":0}}]` through the same `act`, with the context's `frontmostApp` set to whatever is in front.

Measured on Brandon's MacBook Pro (Mac14,5, macOS 26.3, display 1512 by 982 points) on 2026-09-07. TextEdit was brought to the front and its Format menu bar item's Accessibility frame was (209, 0, 66, 33). From the cursor parked at (1000, 600) by a bare move, `act` clicked the frame's centre (242, 16.5) in 10 move reports, 92 ms from the actions being handed over to the click's acknowledgement, the Accessibility search included; a screenshot taken straight afterwards had the Format menu open. Clicking again with the cursor already on the centre took 0 move reports and 39 ms, which is the arrival round proving the app in front and posting nothing. Bare moves, cursor read back afterwards: to (100, 100) in 38 ms, landing at (99.74, 100.40); to (1400, 800) in 60 ms, at (1400.00, 800.05); to (756, 450) in 20 ms, at (756.16, 449.80). Every landing was within half a point.

The mouse exists because macOS protects its consent and approval dialogs from synthetic events, and the virtual mouse is hardware to macOS. That is shown at the layer which separates the two. A program reading mouse input through `IOHIDManager`, which no `CGEventPost` can reach because posting makes no HID report, was run beside a listen-only event tap. A synthetic click at (800, 12) - three CGEvents (moved, left down, left up) from a Terminal allowed under Accessibility - reached the tap and made no HID report at all. The virtual mouse's click at (820, 12) reached both: ten motion reports, then button 1 down and up from `Karabiner DriverKit VirtualHIDPointing 1.8.0`, the tap seeing the click 15 ms after the device did, which is the delay of a report climbing into the window server. So a click from this device lands in an app that ignores synthetic mouse events. Which dialogs refuse them is the other half, and this Mac would not answer it. A click from this device did once dismiss a com.apple.SecurityAgent authentication dialog here, so a protected dialog is reachable - but raising one is not a step this runbook asks for, because it puts a real password prompt on the screen and then drives synthetic input at it, and the measurement is not worth teaching that. No TCC consent alert could be raised to try either, an Accessibility request opening System Settings directly and an app launched from Terminal inheriting its grants. That half is still open, and what stands in the way now is a step earlier than the question. The approvals are given in System Settings, and System Settings publishes nothing to aim at. Opened to the Login Items & Extensions pane with `open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"`, it names its window correctly to `System Events` - `get name of every window` returns "Login Items & Extensions" - and `count of (entire contents of window 1)` returns 0. Setting `AXEnhancedUserInterface` on the process, the usual way to make a SwiftUI application publish a tree to a client that is not VoiceOver, left it at 0, and `lowtalker see` agrees from the other side, reporting the focused element as an AXWindow that holds nothing readable and no alerts. Permission is not what is missing: the same Accessibility-trusted client, in the same run, opened LowTalker's own status menu by clicking its menu bar item and read back every menu item title. So `lowtalker click`, which locates an element by role and title, cannot aim at the Driver Extensions toggle or the Login Items switch, there being nothing there to locate, and the virtual mouse does not resolve it either: it supplies a genuine hardware click, but something still has to say where to click, and the Accessibility frame that would say so is exactly what is absent. Coordinates read off a screenshot are the only aim left, at windows that get moved mid-run. The discriminating test, toggling an approval switch and watching whether it takes, was deliberately not run: both approvals are held on this Mac, and turning one off risks leaving it off, since only a person can turn it back on in that pane. A Mac that has never approved this driver is where that test is free to run.

### Replaying mouse reports on a schedule

`lowtalker pointer play` is for measuring what input does, not for getting something clicked. A harness timing a browser's frames while it scrolls needs input that reaches macOS the way a person's does, the same way on every run, and at times it knows. A browser's own automation posts wheel events it coalesces and timestamps on a clock of its own; this mouse is hardware to macOS. The script is JSON Lines on stdin:

    {"to":{"x":400,"y":350}}
    {"t_ms":0,"down":"left"}
    {"t_ms":8.333,"move":{"dx":4,"dy":0}}
    {"t_ms":16.667,"wheel":{"v":-1,"h":0}}
    {"t_ms":1000,"up":true}

The first line is where the cursor starts, reached by the acceleration loop above before the clock starts. Every line after it is one report at `t_ms` milliseconds from that start: a button down, relative motion in raw counts, wheel ticks, or every button up. Motion is not corrected, because a replay exists to give acceleration identical input each time, and a path the loop steered would ask for different counts on every run. Each count is -127 to 127, one report's worth. A script is refused whole before the cursor moves, naming the line, when a line has a key it does not take or carries two reports, a count is out of range, `t_ms` goes backwards or past an hour, or the script ends with a button held. Waiting for a report, the play asks every 50 ms whether it may go on, so Ctrl-C or the app leaving the front ends a long hold within 50 ms and releases the button, not when the next report is due.

    .build/debug/lowtalker pointer play --into com.apple.Safari < scroll.jsonl

`--into` raises the app first, as `act` does, and the play stops if it leaves the front. Stdout is one `{"report":{"index":…,"scheduled_us":…,"sent_us":…,"acked_us":…}}` per report, then `{"done":{"reports":…,"start_reports":…,"late_us":{"p50":…,"p90":…,"p99":…,"max":…}}}`. The times are microseconds since the Unix epoch: the wall clock read once at the start, plus the monotonic clock's elapsed time, so a browser's `performance.timeOrigin + performance.now()` can be set against them and a clock adjustment mid-run moves none. `sent` is when the report was handed to the mouse and `acked` when the helper acknowledged it; for a button going down, the mouse's reading of whether a system alert is up falls between the two. Lateness is sent minus scheduled; a late report is sent late and never skipped, since skipping it would change the input. The lines are printed after the play, so writing them never makes a report late. A play that stops - the app left the front, a report was refused, Ctrl-C - releases every button, prints the reports that went out and no done line, and exits 1 saying how many of how many went out; an unreachable helper exits 4 or 5 as `act` does.

Two reports at the same `t_ms` go out one after the other, so the second is late by the first's round trip. The app in front is not necessarily the window under the cursor: with TextEdit in front and a full-screen iTerm on another Space covering the point, wheel reports went to iTerm, so a harness has to know its window is on screen at the start.

Measured on Brandon's MacBook Pro (Mac14,5, macOS 26.3) on 2026-09-17, with the Mac in use: 240 one-count moves at 120 Hz, eight runs, went out a median 74 to 88 µs late, p99 143 to 197 µs in seven runs and 1.3 ms in the eighth, and worst 165 µs to 2.6 ms, with 0.3 to 0.4 ms from sent to acknowledged and about half a second of CPU for the two-second play. Getting there took three measurements, on the same script. `ContinuousClock.sleep` with no tolerance, alone, sent reports a median 1.1 to 1.6 ms late and at worst 2.3 ms, for 0.07 s of CPU. Sleeping in `mach_wait_until` on a thread of its own did no better, a median 1.6 ms and a worst of 2.1 ms, which showed the delay was not the timer but the hop back onto the main actor, where every report is posted. So the player sleeps until 2.5 ms before a deadline and watches the clock on the main actor for the rest. Doing that with `ContinuousClock` instead, the same lead and the same CPU, matched the median but not the tail: two of five runs had a report 12 ms and 40 ms late, run beside the waking clock's five whose worst was 2.6 ms; with a 4 ms lead it cost twice the CPU and was still worse at the tail, up to 887 µs.

### Installing

    scripts/virtual-hid-driver install
    scripts/virtual-hid-driver install /Applications/LowTalker.app/Contents/Resources/Karabiner-DriverKit-VirtualHIDDevice.pkg

With no argument the package is downloaded from GitHub. A release carries the same package in its bundle, so the second form installs with no network. Either way the package is checked before installing: against the pinned SHA-256, and against the signature, which must be `Developer ID Installer: Fumihiko Takayama (G43BCU2T37)` on a chain macOS trusts. A carried copy gets no trust for having shipped beside the app. It is copied into the script's own directory first and checked there, so whoever could write beside the app cannot swap the bytes between the check and `installer`.

The package lands in a directory made for that run, inside one fixed directory under the machine's temp area that the script first proves it owns. The run's directory and the package go when the run ends. No two runs share a file, so a build fetching the package cannot replace the bytes an install checked while it waits for `sudo`, and a download or copy that dies partway leaves no older bytes for the checksum to approve.

Measured on 2026-09-16 with the package a Developer ID release carries. With outbound TCP and UDP blocked for root and `_trustd` by a temporary pf anchor, `install` of the carried package completed and the driver read `running`; name lookups for this user failed during the run as well. Under a sandbox profile denying outbound network, `install` took the carried package and verified it before stopping at `sudo`, which the sandbox refuses to run. The package's preinstall and postinstall scripts stop the old client and restart the daemon, and neither reaches the network. A carried copy with one byte changed is refused, before anything is installed, with "does not match the checksum pinned for 8.4.0".

On a Mac that has never approved this driver, activation stops and waits for you:

    Open  System Settings > General > Login Items & Extensions
    Click the (i) beside "Driver Extensions"
    Turn ON  org.pqrs.Karabiner-DriverKit-VirtualHIDDevice
    Authenticate when macOS asks

Then `scripts/virtual-hid-driver expect enabled` confirms it. macOS remembers the approval per developer team and bundle identifier, so a Mac that has ever approved this driver activates silently on reinstall: the extension comes up already switched on, and the missing prompt is expected, not a skipped step.

Each step is confirmed by probing the machine, not by an exit status: the driver Manager exits 0 even when its own output says the request failed, or when handed a bare usage error.

### Removing takes a restart

`remove` deactivates the extension, deletes both installed trees, and forgets the installer receipt. macOS still lists it as `[terminated waiting to uninstall on reboot]`: the files and receipt are gone, but the registration persists. Only restarting the Mac clears it; `sudo systemextensionsctl uninstall` prints "Success" and changes nothing. The verdict in this window is `pending-reboot`, not a failure; after the restart, `scripts/virtual-hid-driver expect absent` confirms removal.

The package installs its own uninstall scripts, `deactivate_driver.sh` and `remove_files.sh`, under its support directory. Neither is used here: the first opens an AppleScript dialog box, so it cannot run unattended, and neither runs `pkgutil --forget`, so the receipt survives. `remove` does that work without the dialog, and forgets the receipt.

### Karabiner-Elements on this Mac

Brandon's MacBook already had Karabiner-Elements 15.5.0. Its installer wrote both receipts, `org.pqrs.Karabiner-Elements` and `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`, in one transaction at the same second. The two products share one Manager app path, one support directory, and one receipt identifier; there is no arrangement where both own the driver. Installing the pinned package upgraded that shared Manager from 6.0.0 to 8.4.0; Karabiner-Elements.app, Karabiner-EventViewer.app, its own support directory and receipt were untouched and remain 15.5.0.

Because those paths are shared, `remove` refuses to run at all while an `org.pqrs.Karabiner-Elements` receipt is present: it would delete the Manager and support tree Karabiner-Elements depends on, and nothing in this script could put them back. It names the product and both paths and stops before deactivating anything. Removing Karabiner-Elements first is the way through, and there is deliberately no flag to skip the check. `install` is not blocked, because it replaces files rather than deleting them. It warns before anything else: it names the Karabiner-Elements version and the two shared paths it is about to replace, then continues. When the receipt cannot be read, it says that instead. `state` lists the Karabiner-Elements receipt in its fact table beside the driver's own readings, so the overlap shows before either verb runs. That line never changes the verdict. If the receipt cannot be read, the line says `unreadable` with the reason, and the verdict still stands.

If Karabiner-Elements is ever launched and repairs its driver, it will install its own bundled copy over the pinned one. On this Mac it is disabled and no Karabiner processes are running, so nothing is competing today. The background task entries `org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon` and `karabiner_grabber` are children of Karabiner-Elements' privileged-daemons bundle, not of the driver package. LowTalker's helper is a client of the driver package's own daemon, which it starts itself, and needs nothing from Karabiner-Elements' entries, so they were left alone.

### What has been verified

On Brandon's MacBook Pro (Mac14,5, macOS 26.3, System Integrity Protection disabled): the stale 1.8.0 registration was deactivated, the files and receipt removed, the state reached `pending-reboot`, package 8.4.0 installed, and the extension activated with no approval click, this Mac having approved it before, reaching `running` with the IORegistry node `org_pqrs_Karabiner_DriverKit_VirtualHIDDeviceRoot` present and no client running. `absent` has not been confirmed here, because it needs a restart.

On inferno.local (Mac16,6, macOS 26.5.1, System Integrity Protection enabled): `absent` was confirmed on a clean machine, and the script runs on the stock `/bin/bash` 3.2 that ships there. The install has not been run there: it needs an administrator password typed at that machine, and the approval click above.

## What is left to set up

    make cli
    .build/debug/lowtalker onboard

prints everything that must hold before low-talker can type, read off this Mac now, with the step for whatever is missing indented under it. On this Mac today:

    Driver extension: running
    Keyboard helper: not registered
      launchd holds no job for the helper. Launch LowTalker Dev once - it
      registers on every launch - and turn it on in
      System Settings > General > Login Items & Extensions if it asks.
    Keyboard Setup Assistant: answered for this keyboard

and, on a Mac whose helper has not started yet, that last row instead reads:

    Keyboard Setup Assistant: will ask on first use
      macOS raises Keyboard Setup Assistant the first time the virtual
      keyboard types, and it takes those keystrokes. The keyboard helper
      files this keyboard's own answer as it starts, so this clears itself
      once the helper above is answering.

Both transcripts are illustrative. `make check-docs` holds this file to the reading words — `running`, `will ask on first use`, and the rest — but nothing checks the indented step text under them against the strings in `Requirement`. Read those steps for their shape; their wording can drift from the program's without anything failing.

Every row is `Name: what was read`, and the exit status is 0 when nothing is left to do and 2 when something is. All three requirements are printed every time, met or not, since a list that showed only what was wrong leaves a reader unable to tell "checked and fine" from "never checked". A fact that could not be read is a row of its own reading `could not be read`, with the reason as its step, and it never counts as met, so a reading nobody managed to take can never come out as ready.

The menu-bar app's status menu shows the same list in the same words while the virtual keyboard is its delivery, and does not read it while the clipboard is. Both surfaces read one list, assembled in `OnboardingProbe.readiness` and nowhere else. The app has no words of its own for `SMAppService.Status` any more: the private `describe(_:)` that turned that enum into user-facing text is gone, so the app and the CLI cannot say different things about the same fact. The menu holds no state either. It is emptied and rebuilt from a fresh reading every time it is about to be shown, in `NSMenuDelegate.menuNeedsUpdate`. Measured on this Mac, that reading makes the menu wait about 220 ms, spent almost entirely in the driver probe's subprocesses. It is paid on every open rather than cached because a cached reading is stale exactly when it matters: right after the user has given the approval the menu was telling them to give.

The driver extension's row reads whichever of the nine verdict words above `lowtalker driver` returns, and each word has its own step, because they are not degrees of one problem: `absent` wants an install, `awaiting-approval` wants the click in Login Items & Extensions, `pending-reboot` wants a restart.

The two steps that want the driver put right name two things, because they have two readers. Someone working from a clone runs `scripts/virtual-hid-driver install`, which fetches the pinned package, checks its checksum and its signature, installs it and then activates it. Someone who installed LowTalker.app has no `scripts/` directory, so those steps also name what that script would have run.

They name different things, because the two states are missing different halves. `install` is two operations and only the first is the package: `sudo installer` puts the payload down, and a separate `Karabiner-VirtualHIDDevice-Manager activate` asks macOS to register it. So `absent` names the package — 8.4.0, at <https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v8.4.0/Karabiner-DriverKit-VirtualHIDDevice-8.4.0.pkg> — and then the activation; `installed-inactive` already has the payload and names the activation alone, at `/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager`. Naming the package to both was the older text, and it was a step that could never move a reader off `installed-inactive`: it told them to install what they already had. Both steps say to run the Manager as the logged-in user and not under sudo, for the reason in the next section.

The version, the URL and the Manager's path live in `DriverPackage` and `DriverProbe` in Swift so onboarding can say them; the script keeps the pins it acts on, because it is the file that fetches the bytes and runs the Manager. `make check-docs` reads the script's own resolved values — by sourcing it, since `PKG_URL` is built from `$PKG_VERSION` and `MANAGER` from `$MANAGER_APP`, and a grep of the assignments hands back the template rather than the value — and fails when a copy disagrees.

### Why the app names the driver install instead of taking it

Onboarding takes the Keyboard Setup Assistant's step and not the driver's, and the reason is not effort. The app is not root, so an install would have to go through the one root process it can reach, which is the keyboard helper — and the helper cannot run on a Mac that has no driver. `Karabiner-VirtualHIDDevice-Daemon`, which the helper reaches or starts before it will serve anything, lives *inside the driver package's own payload*, under the same support directory whose absence is what `absent` means. So the helper exits and launchd restarts it, forever, on exactly the Mac where the install is needed. There is no root for the app to borrow at that moment. `KeyboardTypeAnswerTests` keeps that as a check rather than a claim: it asserts the daemon's path sits under the package's support directory, so if that ever stops being true, this paragraph fails with it.

The second half is that the install could not be finished by root alone even so. Activation must be requested by the console user, because macOS attributes a driver-extension activation to whoever asks and the approval the user gives answers that request — which is why `scripts/virtual-hid-driver` runs the Manager as the logged-in user and takes sudo only for the file steps. An install driven from the app would be root for one half and the user for the other, and the half that needs root is the half that cannot happen yet.

What is left within reach is narrower than the ticket that raised it: on a Mac that is `installed-inactive`, the package is already there and only the activation is missing, and activation is exactly the half the app *can* do as the console user. That is its own ticket, not this one — the row a reader actually meets first is `absent`, and `absent` is the one that is blocked.

The Keyboard Setup Assistant's row reads whether `/Library/Preferences/com.apple.keyboardtype.plist` already holds an answer under the key `10203-5824-0`, this virtual keyboard's product-vendor-country. The file is world-readable, so reading it needs no privilege. Writing it does, and that is the keyboard helper's job as it starts, described above — so this is the only row whose step never asks a reader to install or approve anything. It says which row it is waiting behind: the answer is filed once the keyboard helper is answering, and until then the row reads `will ask on first use`. The reader and the writer take the file and the key from one place, `VirtualKeyboardIdentity`, so the process that writes the answer and the process that reads it back cannot come to mean different files.

So the assistant's row reads one of two things:

- `answered for this keyboard` means the cache already holds an entry under this keyboard's key, and there is nothing to do.
- `will ask on first use` means it does not, and the assistant will take the first line typed.

Both onboarding surfaces name the file and the key nowhere in their steps, which is deliberate and is checked: `RequirementTests` fails if the step ever regrows `sudo`, `defaults`, the domain or the key. It checks both of the step's arms, because `will ask on first use` has two of them and they are chosen by the helper's row above.

Which is the point of reading the helper first. The answer is filed *by* the helper, so what is left to do about a missing one depends entirely on whether the helper has had its chance yet. While the helper is not answering, the step says so and says to wait: the row clears itself once the helper is up. But when the helper *is* answering and the answer is still not there, waiting is advice to wait out something that already happened — the filing itself is the only thing left that can have failed, and the helper logged the reason as it started. That arm sends the reader to the log instead:

    /usr/bin/log show --predicate 'subsystem == "ai.promptctl.low-talker.keyboardd"' --last 1h

A helper whose standing could not be read counts as not answering. That is not the failure going quiet: it is in the helper's own row, which reads `could not be read` and carries the reason, and it is the only honest answer to "has the helper already had its chance" when nobody could look.

The helper's row is read from two sources, because neither alone is enough. `launchctl print system/<label>`, under this installation's own label, says which job actually holds the Mach service, and it takes no sudo, which is what makes the check possible from the app at all: a job that holds the service names it in an `endpoints` block, and a job that asked and lost simply has no such block, launchd not making the loser loud. `SMAppService.status` says whether this app's own registration is approved, and only the app can ask it — a CLI has no registration of its own, so `lowtalker onboard` passes nothing and gets launchd's answer unsharpened. The second source is needed for one thing: telling apart two states launchd renders identically, a helper that was never registered and a helper that is registered and waiting for its approval click. launchd holds no job in either case, and the two want opposite steps.

launchd used to be asked a second time, under the development job's label, so that a lost name could be reported as the development copy having taken it. That reading is gone with the arrangement that made it possible: the two installations no longer share a service, so the other copy can no longer be the holder.

So the helper's row reads one of five things:

- `answering` means the app's job holds the service, and there is nothing to do.
- `registered, but another job holds the service` is a lost name whose holder the app cannot identify. launchd refuses a second job under this installation's label at bootstrap, so the holder is one of two things no label governs: a helper left running from a terminal, or a job filed under some *other* label that names this service — which is what every installation predating the joined labels looks like, and the one a reader misses. Its step names both, `pgrep -fl lowtalker-keyboardd` and `sudo grep -l <service> /Library/LaunchDaemons/*.plist`.
- `a bootstrapped job holds the label, so this app's registration never ran` is the holder the app *can* name. `launchctl bootstrap` refuses a duplicate label, but `SMAppService.register()` is not `bootstrap` and gets no such refusal: a plist job already under the label simply stays, and the app's own copy never spawns. Told apart from the row above by what launchd answers with — a job bootstrapped from a plist reports `path = /Library/LaunchDaemons/…`, where the app's reports `path = (submitted by smd.N)`. Its step names `scripts/keyboard-helper uninstall <flavor>`, which is the plist that has to go.
- `not registered` says to launch this installation's app once, since it registers on every launch.
- `waiting for approval in Login Items & Extensions` says to turn this installation on in System Settings > General > Login Items & Extensions.

The third of those is what this Mac is in right now for the development copy: launchd holds no job under `ai.promptctl.low-talker.keyboardd.dev`, so `lowtalker onboard` and the menu both read `Keyboard helper: not registered` and say to launch the app once, which is the output above.

The app logs every reading it takes, so an agent can read back what the menu is showing without a screen:

    /usr/bin/log show --predicate 'subsystem == "ai.promptctl.low-talker"' --last 5m --style compact

The category is `engine`. Each open writes `helper registration: SMAppService.Status <n>`, then `onboarding: ready` or `onboarding: not ready`, then one `onboarding: <Name>: <what was read>` per requirement. `log` is spelled with its absolute path because zsh has a builtin by that name.

## One-time setup: signing identity

Run once after cloning:

    make signing-identity

Without it, `make app` fails with an xcodebuild error beginning `No certificate matching 'LowTalker Dev' found`. `make cli` and `make helper` stop too, with codesign's `LowTalker Dev: no identity found`: both sign with the identity, which `scripts/signing-identity` reads off `project.yml`, so the app, the CLI and the helper cannot end up signed by different certificates.

### Why a certificate

macOS keys the Microphone, Accessibility, and Input Monitoring grants to the app's code signature, its "designated requirement". For an ad-hoc-signed build that requirement is the hash of the specific binary, so every rebuild is a new app as far as macOS is concerned and the grants are gone. For a certificate-signed build the requirement names the certificate instead, and it survives rebuilds.

### What the command does

`make signing-identity` creates a self-signed code-signing certificate named `LowTalker Dev`, valid for ten years, and imports it into the login keychain pre-authorized for `codesign`. It shows no dialogs and asks for no password. It sets no trust settings on purpose; `codesign` does not need them. Running it a second time refuses with an error, since two certificates with the same name would make builds ambiguous.

The name lives in one place: `project.yml` sets `CODE_SIGN_IDENTITY` to `LowTalker Dev`, and the Makefile reads it from there.

To confirm a build is signed with it:

    codesign -dvvv --requirements - DerivedData/Build/Products/Debug/LowTalker.app

The `designated =>` line should name `certificate leaf = H"..."`, which is stable across builds. An ad-hoc build shows `cdhash H"..."` instead, and that hash changes every build.

### Hardened Runtime and entitlements

Both installations, and everything embedded in each - the helper and the input method bundle - are built with Hardened Runtime, which notarization requires: `project.yml` sets `ENABLE_HARDENED_RUNTIME`. `codesign -dv` on either bundle, on its `Contents/MacOS/lowtalker-keyboardd`, or on its input method bundle under `Contents/Library/InputMethods` shows `flags=0x10000(runtime)`.

The runtime holds a program to a set of restrictions, and each exception is an entitlement. The app carries one, `com.apple.security.device.audio-input`, declared under `entitlements` in `project.yml`; xcodegen writes the plist from there into `App/Generated/`, which is ignored. Built with the runtime on and no entitlements, tccd logged `Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input but it is missing`. A Mac that already granted the microphone kept hearing. A Mac that never granted it would never be asked, and the app would hear nothing. Nothing else failed. Measured on 2026-09-16 on this Mac, both installations were built that way and each was driven through a held chord while a fixture played at the microphone. Through the virtual keyboard, "Hello world, this is Low Talker." was typed into TextEdit 708 ms (development) and 700 ms (release) after key-up. Through the clipboard, it was on the pasteboard 690 ms and 702 ms after key-up. The hardened helpers still admitted the CLI: `lowtalker onboard` read every row met for both flavors, and `lowtalker type` typed through them.

An entitlement goes in only with the failure that needed it, written in the comment beside it in `project.yml`.

After a build that changes only how the helper is signed, rebuild the bundles from scratch (`rm -rf "DerivedData/Build/Products/Debug/LowTalker Dev.app" DerivedData/Build/Products/Debug/LowTalker.app`, then `make app` and `make release`): Xcode's copy phase does not see a re-signed helper as changed, and keeps embedding the old one (low-build-mmp).

### Signing for release

    NOTARY_PROFILE=<profile> scripts/release dist ~/Library/Application\ Support/low-talker/hub   # dist/LowTalker.dmg

`scripts/release` is the whole release, three scripts run in order, each of which also runs alone:

    scripts/sign-release dist ~/Library/Application\ Support/low-talker/hub   # dist/LowTalker.app, Developer ID signed
    NOTARY_PROFILE=<profile> scripts/notarize dist/LowTalker.app                # notarized and stapled
    scripts/make-dmg dist/LowTalker.app dist                                    # dist/LowTalker.dmg, signed
    NOTARY_PROFILE=<profile> scripts/notarize dist/LowTalker.dmg                # notarized and stapled

The app and the disk image are each signed, notarized and stapled. Gatekeeper judges the image when it is mounted and the app again when it is first run. On a Mac with no network, a stapled ticket is the only way it can reach a verdict on either. So the app is stapled before it goes into the image, which cannot change once it is signed, and the image is stapled after. `scripts/release` asks the profile to answer before the build starts, so a missing credential stops it in seconds rather than minutes.

`scripts/sign-release` runs `make release` in the Release configuration, which `project.yml` signs with the `Developer ID Application` certificate for team 6R988MUU27, Hardened Runtime and a secure timestamp. It leaves out `get-task-allow`, which Xcode otherwise signs into both configurations. The bundle carries the default model ("The model store" above), taken from the source the second argument names, as `model download --from` reads it, or from huggingface.co when there is none, and the script requires `model status` to find it whole inside the built bundle. It also carries the pinned driver package as `Contents/Resources/Karabiner-DriverKit-VirtualHIDDevice.pkg` ("Installing" below), fetched by `scripts/virtual-hid-driver fetch` and checked inside the built bundle by `scripts/virtual-hid-driver check`. The build goes into a derived-data directory made for the run and deleted after it, so a helper re-signed without changes to its code is always embedded again (low-build-mmp). It then checks the app, `Contents/MacOS/lowtalker-keyboardd`, and every input method bundle under `Contents/Library/InputMethods` for what the notary service refuses: a signature that is not the team's Developer ID, no Hardened Runtime, no secure timestamp, or `get-task-allow`. The first of those it finds stops it with the binary named. An app carrying no input method bundle fails there too, rather than passing a check that ran zero times. A Debug-signed bundle fails three of the four. The Developer ID certificate lives in the login keychain, and `codesign` signs with it without a prompt.

A Release build's helper admits the Developer ID certificate and nothing else, so the CLI, signed with the dev identity, cannot type through it. A probe compiled from `CallerIdentity.swift` and signed with the Developer ID admitted `dist/LowTalker.app` and its helper, and refused the Debug app and `.build/debug/lowtalker`. Signed with the dev identity, it did the reverse. On 2026-09-21 the installed release was watched doing the same. The helper `SMAppService` registered from `/Applications/LowTalker.app`, approved and running under launchd, logged `callers must satisfy: certificate leaf = H"e8665b1f13003844806a98ce0e76e2d85e22acaa"` at startup, and turned `.build/debug/lowtalker` away when it asked for the release flavor: "the calling process is not signed by this helper's certificate (OSStatus -67050)", which reached the CLI as `NSCocoaErrorDomain 4097`. The app carries that leaf itself, so `codesign --verify -R='certificate leaf = H"e8665b1f13003844806a98ce0e76e2d85e22acaa"' /Applications/LowTalker.app` exits 0.

`scripts/notarize` takes the signed app or a disk image, submits it with `notarytool` under the keychain profile `NOTARY_PROFILE` names, waits, and prints the notary log when the answer is anything but Accepted. It then staples the ticket and requires Gatekeeper to assess the result as `source=Notarized Developer ID`. The profile is made once per Mac with `xcrun notarytool store-credentials <profile>`, from an Apple ID with an app-specific password or from an App Store Connect API key. This Mac's profile is `lowtalker-notary`, and submissions under it have been Accepted since 2026-09-16. A missing profile, a profile that does not exist, and a path that is neither an `.app` nor a `.dmg` each stop the script with a message.

`scripts/make-dmg` puts the app beside a link to `/Applications` in an LZFSE-compressed image, and signs the image with the certificate that signed the app, read off the app's own signature. It refuses an app that is not signed with the team's Developer ID, checks the image for that signature and a secure timestamp, and mounts the image to verify the app as a person will find it. The dev-signed Debug app is refused by name. Measured on 2026-09-16 with the release carrying the default model, the image took 21 s to make and is 482,836,863 bytes. Before notarization, `spctl --assess --type open --context context:primary-signature` rejects it with `source=Unnotarized Developer ID`; after it, the same command accepts the image as `source=Notarized Developer ID`.

`syspolicy_check notary-submission` is no help on this Mac. It reports `Internal Xprotect Error` for this app, for the Debug build, and for a one-line Swift app signed the same way, while iTerm and Karabiner-Elements pass. So the notary service's answer is the one that counts.

### Starting over

To recreate the certificate, delete `LowTalker Dev` and its private key in Keychain Access (login keychain, My Certificates), then run `make signing-identity` again. The new certificate is a new signature, so re-grant the app's permissions in System Settings.

This certificate is for local development only. Nobody trusts it and it cannot distribute the app; release builds sign with Developer ID instead, as "Signing for release" above describes.
