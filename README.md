# muesli

Open-source meeting notes for the Apple ecosystem. Capture calls, meetings and
conversations on your Mac (and later iPhone and Apple Watch), turn them into
summaries and action items, and turn follow-ups into **Mail drafts**. No bot joins your call and there's no subscription. Transcription
runs on-device, and you choose where summaries are generated.

> **Status: step 3.** muesli is a Mac menu-bar app and a command-line tool. Both
> capture your mic *and* system audio, transcribe them on-device, turn the
> transcript into notes (summary, decisions, action items, agreed meetings), and
> after you review them open the follow-ups as **mail drafts**. The iPhone and Watch are next; see the [roadmap](#roadmap).

## How it works

```
 mic ───────────► "Me"   ─┐                                          ┌─► summary, decisions,
                          ├─► SpeechAnalyzer ─► transcript ─► LLM ───┤   action items, meetings
 system audio ──► "Them" ─┘   (on-device)          ▲                └─► email drafts ──► your mail app
 (Core Audio process tap)                          │                    (you review first; nothing is
                                          your own rough notes           opened without your OK)
                                          expanded into clean notes
```

Speakers are labelled by **channel**, not by voice: your microphone is *Me*,
whatever the Mac is playing is *Them*. That's cheap, fast, and right for the
common one-to-many call. It can't tell two remote people apart yet.

## Requirements

- macOS 26 or later, Apple silicon
- Swift 6.2+ toolchain (Xcode 26 or Command Line Tools)

## Quick start

```sh
scripts/build.sh                    # or: swift build -c release
.build/swiftc/muesli doctor         # check permissions, speech model, summarizers
.build/swiftc/muesli record --summarize --backend anthropic   # Ctrl-C to stop
```

Files are saved to `~/Muesli/<date-time>/`: `transcript.md`, `transcript.json`,
and with `--summarize`, `notes.md` and `notes.json`.

```sh
muesli record --locale en-GB --title "Vendor call"
muesli record --no-mic                     # system audio only
muesli record --app zoom                   # only Zoom's audio, not your music
muesli record --duration 1800              # auto-stop after 30 min
muesli transcribe ~/Downloads/call.m4a --speaker them
muesli summarize ~/Muesli/2026-09-25-1430 --backend anthropic --notes my-notes.md
muesli actions   ~/Muesli/2026-09-25-1430      # review, then open email drafts in your mail app
```

The first run asks for **Microphone** and **System Audio Recording** access. In a
terminal, macOS attributes both to your terminal app. The first `record` also
downloads the on-device speech model for your locale (one time).

**Use headphones.** If your speakers are audible to your mic, the other side of
the call is transcribed twice (once as *Them*, once as *Me*).

### Capturing just your call

By default muesli records **everything the Mac plays**, so music or a video in
another tab ends up in your transcript. Choose what to capture instead:

```sh
muesli apps                                  # who is playing audio right now
muesli record --app zoom                     # only Zoom
muesli record --app "Google Chrome,Teams"    # several apps
muesli record --exclude-app "Music,Spotify"  # everything except these
```

Names are matched loosely (a name, a bundle id like `us.zoom.xos`, or part of a
name of 3+ letters), and an app's helper processes come with it: a browser's
per-tab helpers, or a call app's audio helper. muesli **follows the app**: start
recording first, and it begins capturing when the app starts playing audio, and
it says what it's capturing as that changes. `--app` and `--exclude-app` are
mutually exclusive.

Safari plays audio through a per-app WebKit process named after the app
("Safari Graphics and Media"), so `--app safari` should find it; run `muesli apps`
during your call to check what your app is called.

## Menu-bar app

```sh
scripts/bundle-app.sh --install    # builds Muesli.app, copies it to ~/Applications, opens it
```

Muesli lives in the menu bar, with no Dock icon. Its menu has:

- **Start Recording** (⌘R).
- **Record From**: all system audio, one of the apps playing right now, or no system
  audio.
- **Microphone**: the system default input, a specific microphone (remembered,
  and the default is used if it's unplugged), or none.
- While recording: **Show Live Transcript** (⌘T), a floating panel with the
  transcript and a level meter for each side; **Stop & Summarize** (⌘S);
  **Stop Without Summary**; **Discard Recording…**
- In the live panel, **Copy All** copies the whole transcript with timestamps and
  times of day, and the **Ask** tab answers questions about the meeting so far
  ("what did we decide about the budget?") with Apple Intelligence. Answers stay
  on your Mac, unless your summarizer is Private Cloud Compute, which holds more
  of a long meeting. When a meeting is too long to fit, the newest part is used
  and the answer says which part it saw. Questions still work after you stop,
  via **Show Last Transcript**.
- **Recent Meetings**: open notes or the transcript, **Review Email Drafts…**,
  **Summarize Now**, show in Finder.
- **Summarize With**, **Speech Engine**, **Language**, **Summarize When Stopped**.
- **Check Setup…** (`muesli doctor` as a window) and **Settings…** (⌘,).

When notes have email drafts, a notification offers **Review**. It opens a
checklist of drafts, and nothing is opened until you press **Open**.

Muesli asks for microphone access when it first starts, so the prompt doesn't
interrupt your first meeting.

The app has its own permissions, separate from your terminal's. If the *Them*
meter stays at "silent" while a call is playing, allow Muesli under **Privacy &
Security → Screen & System Audio Recording**; Muesli also warns you about this
during a recording. API keys are kept in the Keychain, because an app opened
from Finder doesn't see your shell's environment variables.

Without a code-signing identity the app is signed ad hoc, and macOS asks for
permissions again after every rebuild. Set `MUESLI_SIGN_IDENTITY` to avoid that
(see `scripts/bundle-app.sh`).

## Speech engines

muesli has two speech engines. Use Apple's by default, and Whisper when you need it.

| | Apple (`--engine apple`, default) | Whisper (`--engine whisper`) |
|---|---|---|
| Languages | 25 on macOS 27 (no Arabic, Russian, Turkish, Dutch, Thai, Vietnamese, Hebrew, Polish) | 99, detected automatically |
| Live text while recording | yes | no: it transcribes after you stop |
| Speed (M1 Max) | about 50–60× real time | about 3–7× real time |
| Needs | nothing | `python3 -m pip install mlx-whisper` and a one-time ~3 GB model download |
| Runs on | Mac, iPhone (Watch audio goes to the iPhone) | Mac only, for now |

`--engine apple+whisper` gives you the live Apple text as a draft, then replaces it
with Whisper's as the final transcript (the draft is kept as `transcript.apple.json`).

```sh
muesli record --engine whisper                       # 99 languages, detected per stream
muesli record --engine apple+whisper --keep-audio    # live draft, Whisper as final text
muesli transcribe call.m4a --engine whisper --whisper-language ar
muesli transcribe ~/Muesli/2026-09-25-1430           # re-run Whisper on a kept recording
muesli doctor                                        # is mlx-whisper installed? model downloaded?
```

**Why not just Whisper everywhere?** Both were measured on an M1 Max MacBook Pro (8.6 minutes of
English read speech, plus noisy and phone-band-limited copies; word error rate,
lower is better):

| | Whisper, stock settings | Whisper, muesli's pipeline | Apple |
|---|---|---|---|
| Clean speech | 5.0% | 3.5% | 3.5% |
| Background noise (≈10 dB SNR) | 15.4% | 5.6% | 6.0% |
| Phone-call quality | 12.4% (101 extra words) | 3.7% | 4.4% |

Stock Whisper is unsafe for meetings: it wrote "you you" for a minute of silence,
"Thank you. Thank you." for quiet noise, and looped on phone audio. muesli's
pipeline fixes that, and then it's about as accurate as Apple's engine, not clearly
better. **Treat differences under about a point as noise:** this is one run on
English audiobook speech with synthetic degradation, not real meetings, accents,
crosstalk or non-English speech. The pipeline:

1. **Speech gate:** only stretches that contain speech are sent to Whisper. muesli
   records the mic and system audio as separate streams and each is silent whenever
   the other side talks, so this matters. It's an energy gate, not a neural VAD:
   steady noise and silence are kept out, but music or crosstalk are not.
2. **`condition_on_previous_text` off:** the setting behind the looping.
3. **A quality filter** drops segments Whisper itself flags as non-speech.

**A hazard with Apple's engine:** for a language it doesn't support, it doesn't
refuse; with the wrong locale it can return confident phonetic gibberish (Arabic
speech came back as garbled English). If your meetings aren't in a language Apple
lists, use `--engine whisper`.

**Audio retention.** Whisper works from the recording, so `--engine whisper` and
`apple+whisper` save each stream as a 16 kHz mono WAV under `<session>/audio/`
(about 115 MB per hour per stream). It is deleted once Whisper succeeds unless you
pass `--keep-audio`, and it's kept, with the command to retry, if Whisper fails.

**Limits.** Each stretch of speech costs a full 30-second Whisper window, which is
why this runs at 3–7× real time rather than the ~17× stock Whisper reaches, so an
hour-long call can take 10–20 minutes. The recording and Whisper flows were tested
on files; recording *live* with `--engine whisper` was only confirmed for the
no-audio path, since the Mac's audio output was unavailable during testing.

Set `MUESLI_PYTHON` to the interpreter that has mlx-whisper if muesli can't find it,
and `--whisper-model` to try another model (for example
`mlx-community/whisper-large-v3-turbo`, not yet measured).

## Summaries

Pick where the summary is generated with `--backend`:

| Backend | Where it runs | Cost | Notes |
|---|---|---|---|
| `apple` | On your Mac (Apple Intelligence) | free | Default when available. Needs Apple Intelligence enabled and its model downloaded. |
| `apple-cloud` | Apple Private Cloud Compute (macOS 27+) | free within Apple's quota | Larger model and context. Transcript text leaves the Mac under Apple's stateless-processing guarantees. |
| `anthropic` | Claude API, with `$ANTHROPIC_API_KEY` | pay per use | Best quality. Default model `claude-opus-5`; change it with `--model`. |
| `openai` | Any OpenAI-compatible server | free if local | llama.cpp `llama-server`, Ollama, LM Studio, vLLM. Needs `--base-url` and `--model`. |

muesli never chooses a network backend for you, and it prints a note whenever
transcript text is about to leave your Mac. API keys are read only from the
environment, never from command-line arguments.

```sh
# Claude, cheaper model:
export ANTHROPIC_API_KEY=…
muesli summarize <session-folder> --backend anthropic --model claude-sonnet-5

# Fully local with Ollama:
muesli summarize <session-folder> --backend openai \
  --base-url http://localhost:11434/v1 --model qwen3:8b --context-tokens 8192
```

**Your own notes:** pass `--notes my-notes.md` and muesli expands your rough
bullets into clean notes using what was actually said, which is the core of
Granola-style note-taking.

**Dates are resolved for you.** "By Monday" becomes a real `YYYY-MM-DD` using the
meeting's date and time zone. muesli validates every date: an impossible one, or
one before the meeting, is dropped and the spoken words are kept.

**Long meetings** that don't fit a model's context window are split, summarized in
parts and merged automatically.

**Ollama users:** set `--context-tokens` to the context your server *actually*
uses. Ollama silently truncates prompts beyond its `num_ctx`; raise it with
`OLLAMA_CONTEXT_LENGTH` if you need more.

### Cost

Rough estimates, from list prices, for one hour-long meeting (about 15k tokens in,
about 3k out, thinking included). Not measured, so check your own bill:

| Model | ≈ per meeting | ≈ 20 meetings a month |
|---|---|---|
| `apple`, `apple-cloud`, local `openai` | $0 | $0 |
| `claude-haiku-4-5` | $0.03 | $0.60 |
| `claude-sonnet-5` | $0.06 | $1.20 |
| `claude-opus-5` (default) | $0.15 | $3.00 |

## Email drafts

`muesli actions <session>` lists the email drafts from the notes. Nothing is
opened until you approve it.

```
Proposed from “Launch sync” · Fri, 25 Sep 2026

Email drafts (opened in your mail app; never sent)
  [x] 1. Update on the launch — no recipient address yet · add an address for Board

Open which? [Enter = checked · a = all · n = none · or numbers like 1,3-4]:
```

- **Drafts only.** Each opens a pre-filled compose window in your default mail
  client via a `mailto:` link. muesli can't send mail. It never invents an
  address: names like "Board" are left for you to fill in.
- **No duplicates.** muesli records what it opened in `applied.json` next to the
  notes, so running `actions` again (even after re-summarizing) only proposes what's
  new. `--force` overrides.
- **Scripts:** `--dry-run` only prints, `--yes` opens the checked drafts and `--all`
  opens everything. Without a terminal and without `--yes` or `--all`, muesli
  refuses to open anything.

Action items and agreed meetings stay in `notes.md` as a checklist and a list;
muesli doesn't add them to Reminders or Calendar.

## Layout

| Target | What it does | Platforms |
|---|---|---|
| `MuesliCore` | Transcript and notes models, notes schema, prompts, chunking + merge, date validation, the review plan and ledger, `mailto:` drafts, the speech gate, markdown rendering | any Apple platform |
| `MuesliAudio` | Mic capture, system-audio tap (all, or chosen apps, followed live), file source, 16 kHz WAV recorder | macOS |
| `MuesliTranscribe` | Apple `SpeechAnalyzer` wrapper (live) and the Whisper engine (via mlx-whisper) | macOS 26+ |
| `MuesliSummarize` | Backends: Apple Foundation Models, Claude (raw HTTP), OpenAI-compatible | macOS 26+ |
| `muesli` | The CLI | macOS |

The notes format is defined once (`NotesSchema`) and rendered as a JSON Schema for
Claude and OpenAI-compatible servers, and as a runtime `DynamicGenerationSchema`
for Apple's models, so the backends can't drift apart.

## Build & test

```sh
swift build && swift test           # normal path
scripts/build.sh && scripts/test.sh # fallback: calls swiftc directly
```

The fallback scripts exist because some Command Line Tools betas ship a broken
SwiftPM manifest library (every `Package.swift` fails to link). If `swift build`
works for you, ignore them.

The `MuesliTranscribe` tests run the real recognizer against a spoken fixture, so
they need the en-US speech model (downloaded automatically on first run). The
backend tests use a mock HTTP server and make no network calls.

## Roadmap

- [x] **0.** Dual-stream capture → on-device transcript (CLI)
- [x] **1.** Summaries + action extraction behind a `NotesGenerator` protocol;
      merges your typed notes with the transcript
- [x] **2.** Review → mail drafts (`mailto:`; drafts only, never auto-send), with
      a ledger. (Reminders and Calendar were here once and have been removed.)
- [x] **3.** Mac menu-bar app: live transcript, review window, microphone choice
- [ ] **4.** iPhone app for in-person capture, synced via CloudKit / iCloud Drive
- [ ] **5.** Apple Watch as a capture device (SpeechAnalyzer isn't on watchOS, so
      audio goes to the iPhone for transcription)
- [ ] Fill email recipients from Contacts
- [x] Capture chosen apps only (`--app` / `--exclude-app`) instead of all system audio
- [x] Whisper as a second speech engine (99 languages), gated and safeguarded
- [ ] Pack speech stretches into shared Whisper windows for speed; try
      `large-v3-turbo`; whisper.cpp / WhisperKit so it can run on iPhone; a neural VAD
- [ ] Echo de-duplication between *Me* and *Them*
- [ ] Split the notes request into smaller ones so Apple's small on-device context
      window can be used on long meetings

## Privacy and consent

Audio and transcripts stay on your machine. Transcription makes no network calls
(other than Apple's one-time speech-model download). Text leaves your Mac only if
you pick `anthropic`, `apple-cloud`, or an `openai` server that isn't local, and
muesli says so each time.

Recording other people may require their consent depending on where you are and
who you're recording. That's your responsibility. Tell people you're recording.

## License

[MIT](LICENSE)
