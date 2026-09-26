# muesli

Open-source meeting notes for the Apple ecosystem. Capture calls, meetings and
conversations on your Mac (and later iPhone and Apple Watch), turn them into
summaries and action items, and push those into **Reminders**, **Calendar** and
**Mail drafts**. It runs on-device, with no bot joining your call and no
subscription.

> **Status: step 0.** Right now muesli is a command-line tool that captures
> your mic *and* system audio and transcribes both on-device. Summaries, actions
> and the apps are next; see the [roadmap](#roadmap).

## How it works

```
 mic ───────────► "Me"   ─┐
                          ├─► SpeechAnalyzer (on-device) ─► merged, timestamped transcript
 system audio ──► "Them" ─┘
 (Core Audio process tap: Zoom, Meet, Teams, FaceTime, browser…)
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
.build/swiftc/muesli doctor         # check permissions + speech model
.build/swiftc/muesli record         # Ctrl-C to stop and save
```

Transcripts are saved to `~/Muesli/<date-time>/transcript.md` and
`transcript.json`.

```sh
muesli record --locale en-GB --title "Vendor call"
muesli record --no-mic                     # system audio only
muesli record --duration 1800              # auto-stop after 30 min
muesli transcribe ~/Downloads/call.m4a --speaker them
```

The first run asks for **Microphone** and **System Audio Recording** access. In
a terminal, macOS attributes both to your terminal app. The first `record`
also downloads the on-device speech model for your locale (one time).

**Use headphones.** If your speakers are audible to your mic, the other side of
the call is transcribed twice (once as *Them*, once as *Me*). De-duplication is
on the roadmap.

## Layout

| Target | What it does | Platforms |
|---|---|---|
| `MuesliCore` | `Transcript` / segment models, markdown + plain-text rendering | any Apple platform |
| `MuesliAudio` | Mic capture, system-audio tap, file source | macOS |
| `MuesliTranscribe` | `SpeechAnalyzer` wrapper, model download, stream → segments | macOS 26+ |
| `muesli` | The CLI | macOS |

## Build & test

```sh
swift build && swift test           # normal path
scripts/build.sh && scripts/test.sh # fallback: calls swiftc directly
```

The fallback scripts exist because some Command Line Tools betas ship a broken
SwiftPM manifest library (every `Package.swift` fails to link). If `swift build`
works for you, ignore them.

The `MuesliTranscribe` tests run the real recognizer against a spoken fixture,
so they need the en-US speech model (downloaded automatically on first run).

## Roadmap

- [x] **0.** Dual-stream capture → on-device transcript (CLI)
- [ ] **1.** Summaries + action extraction behind a `Summarizer` protocol
      (Apple Foundation Models on-device; local llama.cpp/MLX; bring-your-own-key
      cloud), merging your typed notes with the transcript
- [ ] **2.** Review sheet → Reminders, Calendar events, Mail drafts (EventKit;
      drafts only, never auto-send)
- [ ] **3.** Mac menu-bar app: live transcript, notes pane, calendar-aware start
- [ ] **4.** iPhone app for in-person capture, synced via CloudKit / iCloud Drive
- [ ] **5.** Apple Watch as a capture device (SpeechAnalyzer isn't on watchOS, so
      audio goes to the iPhone for transcription)
- [ ] Echo de-duplication between *Me* and *Them*; optional Whisper/Parakeet backend

## Privacy and consent

Audio and transcripts stay on your machine; the default pipeline makes no
network calls (other than Apple's one-time speech-model download). Only
cloud-backed summarizers, once added, send text to a provider, and only if you
configure one.

Recording other people may require their consent depending on where you are and
who you're recording. That's your responsibility. Tell people you're recording.

## License

[MIT](LICENSE)
