# muesli

Open-source meeting notes for the Apple ecosystem. Capture calls, meetings and
conversations on your Mac (and later iPhone and Apple Watch), turn them into
summaries and action items, and push those into **Reminders**, **Calendar** and
**Mail drafts**. No bot joins your call and there's no subscription. Transcription
runs on-device, and you choose where summaries are generated.

> **Status: step 2.** muesli is a command-line tool that captures your mic *and*
> system audio, transcribes both on-device, turns the transcript into notes, and
> after you review them adds the action items to **Reminders**, events to
> **Calendar** and follow-ups to a **mail draft**. The menu-bar app, iPhone and
> Watch are next; see the [roadmap](#roadmap).

## How it works

```
 mic ───────────► "Me"   ─┐                                          ┌─► summary, decisions
                          ├─► SpeechAnalyzer ─► transcript ─► LLM ───┼─► action items ─► Reminders
 system audio ──► "Them" ─┘   (on-device)          ▲                ├─► events ────────► Calendar
 (Core Audio process tap)                          │                └─► email drafts ──► your mail app
                                          your own rough notes        (you review first; nothing is
                                          expanded into clean notes    created without your OK)
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
muesli actions   ~/Muesli/2026-09-25-1430      # review, then add to Reminders / Calendar / Mail
muesli undo      ~/Muesli/2026-09-25-1430      # remove what muesli added
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

## Reminders, Calendar and Mail

`muesli actions <session>` turns the notes into a numbered review list. Nothing is
created until you approve it.

```
Proposed from “Launch sync” · Fri, 25 Sep 2026

Reminders
  [x] 1. Send the revised budget to finance — due Mon 28 Sep · Me
  [ ] 2. Waiting on Sarah: Review the contract — due Wed 30 Sep · Sarah

Calendar
  [x] 3. Vendor follow-up call — Fri 2 Oct, 15:00–15:30 · with Bob

Email drafts (opened in your mail app; never sent)
  [x] 4. Update on the launch — no recipient address yet · add an address for Board

Add which? [Enter = checked · a = all · n = none · or numbers like 1,3-4]:
```

- **Your tasks are pre-checked; other people's aren't.** Someone else's action
  item is offered as a "Waiting on Sarah: …" reminder, unchecked.
- **Events** are created in the meeting's time zone, so 15:00 in London stays
  15:00 London wherever your Mac is. A date with no time becomes all-day. An event
  with no date is listed under "Not proposed" with the reason.
- **Email drafts** open a pre-filled compose window in your default mail client via
  a `mailto:` link. muesli can't send mail. It never invents an address: names
  like "Board" are left for you to fill in.
- **No duplicates.** muesli records what it created in `applied.json` next to the
  notes, so running `actions` again (even after re-summarizing) only proposes what's
  new. `--force` overrides.
- **Undo.** `muesli undo <session>` removes the reminders and events it added.
  Email drafts can't be undone; close them in your mail app.
- **Scripts:** `--dry-run` only prints, `--yes` applies the checked items, `--all`
  applies everything, `--only reminders,events,emails` narrows it, and
  `--reminders-list` / `--calendar` pick where things go. Without a terminal and
  without `--yes` or `--all`, muesli refuses to apply anything.

**Permissions.** Reminders needs full access. Calendar works with *write-only*
access for adding events, but choosing a calendar by name and `undo` need *full*
access; muesli tells you when that's the reason something failed. Grant them to
your terminal app in System Settings → Privacy & Security. `muesli doctor` shows
where you stand.

## Layout

| Target | What it does | Platforms |
|---|---|---|
| `MuesliCore` | Transcript and notes models, notes schema, prompts, chunking + merge, date validation, the review plan and ledger, `mailto:` drafts, markdown rendering | any Apple platform |
| `MuesliAudio` | Mic capture, system-audio tap (all, or chosen apps, followed live), file source | macOS |
| `MuesliTranscribe` | `SpeechAnalyzer` wrapper, model download, stream → segments | macOS 26+ |
| `MuesliSummarize` | Backends: Apple Foundation Models, Claude (raw HTTP), OpenAI-compatible | macOS 26+ |
| `MuesliActions` | Reminders and Calendar via EventKit: create, and undo | macOS 26+, iOS |
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
- [x] **2.** Review → Reminders, Calendar events, mail drafts (EventKit and
      `mailto:`; drafts only, never auto-send), with a ledger and `undo`
- [ ] **3.** Mac menu-bar app: live transcript, notes pane, calendar-aware start
- [ ] **4.** iPhone app for in-person capture, synced via CloudKit / iCloud Drive
- [ ] **5.** Apple Watch as a capture device (SpeechAnalyzer isn't on watchOS, so
      audio goes to the iPhone for transcription)
- [ ] Fill email recipients from Contacts; warn about calendar conflicts
- [x] Capture chosen apps only (`--app` / `--exclude-app`) instead of all system audio
- [ ] Echo de-duplication between *Me* and *Them*; optional Whisper/Parakeet backend
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
