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

prints the transcript, then one line per word with its start, end, and confidence. Pass `--model` with another folder name from the whisperkit-coreml repo to try a different one. `--vocabulary` names a term the speaker is expected to say, spelled as it should be written; repeat it for several. The engine is told the vocabulary ahead of the audio, the way a mode will tell it the user's names or the running apps, and "The latency harness" below shows what that does.

`make cli` is `swift build` plus a re-signing step; the section below says why it matters.

### The model store

The app and the CLI share one model directory, `~/Library/Application Support/low-talker/hub`, laid out the way the Hugging Face hub lays out its cache. The first `transcribe`, or the first app launch, downloads the default Whisper model (about 632 MB) into it and records a manifest of the files and their sizes. Every launch after that checks the manifest against the files and loads straight from disk, so the app works offline once the first load has finished.

    .build/debug/lowtalker model status      # where the model stands; exits 1 unless installed
    .build/debug/lowtalker model download    # fetch it, or finish a download that stopped

A download that stopped part way leaves no manifest, so the model reads as missing and the next download resumes it: the hub client skips every file already on disk that its own sidecar marks as downloaded. A listed file that is no longer there as recorded reads as damaged, and `model download` repairs it by deleting the files the manifest rejects before asking the hub client for the model; the client never hashes a file it finds on disk, so a truncated file would otherwise pass. A manifest that no longer parses is not repaired: `model download` stops and says to delete it and the model's folder, and the next download starts fresh. The app and the CLI may both start a download; the second waits for the first. Pass `--models-dir` to either command, or to `transcribe`, to use a different directory.

The tokenizer is not part of the manifest: WhisperKit fetches it into the same directory during the first load and reads it from there afterwards.

### Load times and the Neural Engine cache

Loading the model means Core ML compiling it for this Mac's Neural Engine, which takes minutes for the default model. macOS caches the result, keyed by the model's path and by the **code-signing identifier** of the process that loaded it, and evicts the cache after an OS update. Measured on an M2 Max with the default model; the smaller models in the table under "The latency harness" compile and load faster:

| Situation | Load |
|---|---|
| First load of a model, after an OS update, or after the store moved | 1.5 to 4.5 minutes |
| Same signing identifier, model already compiled | 1.5 to 7 seconds |
| A binary with a new signing identifier | 2 to 4 minutes again |

`swift build` links a fresh identifier into every binary it produces, so a plain `swift run` pays the full compile after every rebuild. `make cli` re-signs the built binary with the fixed identifier `lowtalker`, which keeps the cache warm across rebuilds. The app's identifier is its bundle id, set by its certificate signature, so `make app` builds keep the cache warm on their own.

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

    tccutil reset Microphone ltd.deadgrass.low-talker

## Hotkey

    swift run lowtalker hotkey                      # print each press of Right Option until interrupted
    swift run lowtalker hotkey --tap-threshold 400  # a press under 400 ms is a tap

Each press prints `began` as the key goes down. A release after the threshold (250 ms by default) prints a line beginning `ended (hold)`; a release before it is a tap, which leaves listening on until the next press of the key prints one beginning `ended (tap)`. Each `ended` line carries `lapses`, how often macOS has switched the tap off and it was switched back on; a press during a lapse reaches the frontmost app and is not reported, and a lapse ends any press in progress. While the tap is on, a Right Option pressed on its own never reaches the frontmost app: its down and up are swallowed. Pressed with another modifier already held it is a different chord and passes through, and Left Option is untouched.

The tap needs Input Monitoring and Accessibility. macOS charges a terminal command's tap to the terminal, so the command fails with `the session refused an event tap` until the terminal has both under System Settings > Privacy & Security; the app asks on its own behalf.

## Paste

    swift run lowtalker paste "hello there"            # paste into the frontmost app now
    swift run lowtalker paste "hello there" --delay 3  # three seconds to bring the receiving app forward

The text goes on the pasteboard and the frontmost app is asked to paste through Accessibility: its own Paste menu item, the one bound to Cmd+V, is pressed, and the prior pasteboard contents go back once the app has run it, every item and every type, images included. A posted Cmd+V says nothing about when the app acts on it, and a clipboard manager pulling the pasteboard is indistinguishable from the paste, so neither serves as the signal. No wait is invented: Accessibility gives up on an app that does not answer after its own messaging timeout, 1.5 s by default, and the pasteboard goes back then. The line printed names the app and says whether the pasteboard was `restored`; when something else takes the pasteboard during the paste, that is left in place and the line says so. With no app frontmost, as at the lock screen, there is nothing to ask and the command says so. An app with no Cmd+V menu item cannot be pasted into this way; the command says so and names it. An app whose Paste item is disabled is not pressed either, since a press on a disabled item does nothing: apps validate that item on a one-second clock of their own, so the command gives a reading taken before the text went on the pasteboard one period to change before it says the item is disabled. An app that takes the press and then stops answering leaves the paste unknown, and the command says so rather than that it landed or did not: retrying may paste twice. The item carries nspasteboard.org's transient marker, so clipboard managers that honor it do not keep the dictated text.

Pressing another app's menu item needs Accessibility, charged to the terminal for this command; without it the command prints `Accessibility is off for the calling process; grant it in System Settings > Privacy & Security > Accessibility`.

`scripts/live-paste-check` pastes into TextEdit and Terminal, checks what landed (the file TextEdit writes when its window is closed, the text Terminal echoes, read through Accessibility), and compares the pasteboard before and after. It needs an unlocked screen and uses no AppleScript, because an Automation prompt nobody answers becomes a denial.

## The virtual keyboard driver

LowTalker types by driving a virtual keyboard macOS treats as real hardware: the driver extension `Karabiner-DriverKit-VirtualHIDDevice`, a public-domain pqrs-org package that ships its own installer. Karabiner-Elements is a separate, much larger application by the same author; this project uses only the driver package and never installs or requires it.

`scripts/virtual-hid-driver` does the work, in four verbs:

    scripts/virtual-hid-driver state             # the machine's driver state
    scripts/virtual-hid-driver expect <verdict>  # assert that state
    scripts/virtual-hid-driver install           # download, verify, install, activate
    scripts/virtual-hid-driver remove            # deactivate, delete, forget receipt

`state` prints a fact table to stderr for a reader and one verdict word to stdout, so `$(scripts/virtual-hid-driver state)` is exactly the verdict. The verdicts are `absent`, `installed-inactive`, `awaiting-approval`, `disabled`, `enabled`, `running`, `pending-reboot`, `residue`, and `unknown`. `enabled` means macOS has the extension switched on; `running` means that and the driver has published its node in the IORegistry. `running` is the fully working state.

Run it as the logged-in user, never under `sudo`; it takes sudo itself for the file steps. macOS attributes the activation request to whoever makes it, and your approval answers that request.

Two version numbers travel together and are not the same. The package is 8.4.0 and carries the Manager and Daemon helper apps; the driver extension inside it is 1.8.0, which is what `systemextensionsctl` reports. It has not moved across many package releases, so a package upgrade that leaves `systemextensionsctl` still reading 1.8.0 has not failed. The script is authoritative for both numbers, and pins the package's SHA-256 checksum besides. This file quotes the versions, not the checksum, and `make check-docs` fails when a number quoted here disagrees with the script.

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

The daemon is a prerequisite and nothing starts it. The public package installs no launchd job for it, and `scripts/virtual-hid-driver state` reporting `running` describes the driver extension alone: it says nothing about whether anything can type. Start the daemon by hand:

    sudo nohup "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon" &

`sudo launchctl list | grep pqrs` does return a job, which is confusing: that job is the driver extension itself, running as user `_driverkit` under macOS's system-extension machinery, not the daemon.

`type` takes the target app's bundle id as an argument and refuses to type into anything else. It raises the named app, waits for macOS to agree it is frontmost, and re-checks before every keystroke. If the app will not come forward, nothing is posted at all:

    com.apple.TextEdit would not come to the front, com.googlecode.iterm2 is there; nothing was typed

Once typing has begun that promise is no longer available to make. A keystroke cannot be recalled, so an app that takes the front mid-run leaves a fragment in the target, and the refusal says how long it is rather than claiming the run posted nothing:

    com.googlecode.iterm2 is frontmost, not com.apple.TextEdit. 34 of 500 characters had been posted and acknowledged before this, and the rest were not sent

That is deliberate. An earlier version typed into whatever happened to be frontmost, and once delivered its text into the operator's own terminal.

The alphabet is the keyboard layout's own. `KeyboardLayout` asks macOS what every key types bare, under Shift, under Option, and under both, and keeps the answers backwards, so a character costs whatever keys a person would press for it: `\u00e9` is Option-E and then E, a curly quote is one key under Option, and an em dash is Shift-Option-hyphen. A character no key can reach is refused by name before the daemon is touched, so a refusal never leaves a half-typed line; emoji and the scripts the layout does not carry are outside the alphabet by design, since this types a keyboard and a keyboard has the keys it has.

Which layout matters, and a privileged process cannot find out. The driver sends HID usages and macOS turns them into characters using whichever layout the console user is on, so the keys have to be computed for that layout and not another. Text Input Sources answers per process: with this Mac switched to Dvorak, the console user is told `com.apple.keylayout.Dvorak` and the same call under `sudo` is told `com.apple.keylayout.US`. Typing the US keys under Dvorak put `yd. 'gcjt xpr,b` on screen for `the quick brown`, and every check the command makes still passed, because the daemon acknowledged all of it and the screen genuinely held what had been typed. That is why text becomes keystrokes on the user's side of the privilege boundary and only keystrokes cross it. `dext type` runs wholly as root and so cannot read the console user's layout at all: it prints the layout it used on every run, and `--layout <input source id>` names one when the machine is not on root's US. Typed that way, `the quick brown fox jumps over the lazy dog` lands exactly on a machine switched to Dvorak.

The first keystroke waits up to about a second after the connection is made. That is not the hardware. pqrs's daemon polls the driver for readiness on a one-second timer, so readiness is discovered on the next tick rather than when it happens. Once the driver is ready, a character reaches the screen in roughly 10 to 35 ms. Longer text is another matter. Each report is awaited rather than fired, because reports posted back to back are lost, and a lost key-up leaves its key held for macOS to repeat: an unpaced 500-character run ends in hundreds of one shifted character. Awaiting them fixes that and is not a sleep, since the daemon answers every request, but it does not make length safe either: half of twelve 500-character runs came out wrong. Where they go is measured rather than guessed. The app's own event tap counts the keys that arrive, and on every bad run it saw fewer than the 500 the daemon had already acknowledged — as few as 469, and once a matched down and up together, so that keystroke never became an event at all. The acknowledgement is not a delivery receipt, and the loss is under it, in the driver. Nor is a short document the only way it shows: one run lost 41 key-ups and macOS repeated the keys it left held into 608 characters.

Then the rate changed and the loss went with it. Through the VirtualKeyboard module the same burst takes 320 to 370 ms where the spike's took 167 to 220, and sixteen runs of 500 characters landed all 500 — tap downs, tap ups, modifiers and document all exact, every run. The control is a 500-character run with nothing shifted, which puts exactly the reports on the wire that the spike put there: 323 ms, complete and in order. So the loss is rate-dependent, and the rate that loses is above three reports per millisecond and at or below six. That is a bound and not a characterisation — sixteen runs at one rate say where the cliff is not — and finding it is the typist's work, not the driver's.

macOS raises the Keyboard Setup Assistant the first time the virtual keyboard appears; it steals focus and asks for a physical keypress. It caches its answer in `/Library/Preferences/com.apple.keyboardtype.plist`, keyed `<product>-<vendor>-<country>`, so writing this device's own entry stops it returning:

    sudo defaults write /Library/Preferences/com.apple.keyboardtype \
      keyboardtype -dict-add "10203-5824-0" -int 40      # 40 = ANSI

`watch` runs as the logged-in user and needs the terminal's Input Monitoring and Accessibility, as `hotkey` does. It sees the synthetic keys too: the app's own tap observes the keys the app types, which is a thing anything built on this has to account for.

### Installing

    scripts/virtual-hid-driver install

The download is checked twice before installing: against the pinned SHA-256, and against the signature, which must be `Developer ID Installer: Fumihiko Takayama (G43BCU2T37)`.

The package lands in one fixed directory under the machine's temp area and stays there. The script removes no directories: it deletes that single downloaded file before fetching again, so a download that dies partway cannot leave older bytes behind for the checksum to approve.

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

Because those paths are shared, `remove` refuses to run at all while an `org.pqrs.Karabiner-Elements` receipt is present: it would delete the Manager and support tree Karabiner-Elements depends on, and nothing in this script could put them back. It names the product and both paths and stops before deactivating anything. Removing Karabiner-Elements first is the way through, and there is deliberately no flag to skip the check. `install` is not blocked, because it replaces files rather than deleting them.

If Karabiner-Elements is ever launched and repairs its driver, it will install its own bundled copy over the pinned one. On this Mac it is disabled and no Karabiner processes are running, so nothing is competing today. The background task entries `org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon` and `karabiner_grabber` are children of Karabiner-Elements' privileged-daemons bundle, not of the driver package; LowTalker needs no pqrs daemon, its own helper opening the extension directly, so they were left alone.

### What has been verified

On Brandon's MacBook Pro (Mac14,5, macOS 26.3, System Integrity Protection disabled): the stale 1.8.0 registration was deactivated, the files and receipt removed, the state reached `pending-reboot`, package 8.4.0 installed, and the extension activated with no approval click, this Mac having approved it before, reaching `running` with the IORegistry node `org_pqrs_Karabiner_DriverKit_VirtualHIDDeviceRoot` present and no client running. `absent` has not been confirmed here, because it needs a restart.

On inferno.local (Mac16,6, macOS 26.5.1, System Integrity Protection enabled): `absent` was confirmed on a clean machine, and the script runs on the stock `/bin/bash` 3.2 that ships there. The install has not been run there: it needs an administrator password typed at that machine, and the approval click above.

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
