<!-- iOS sibling: ../quill-ios — same WhisperKit engine and same on-disk
     session schema, but its own model picker, diarization, and notes
     backends. -->
# quill-app

Menu-bar meeting recorder for macOS — record any time, transcribe on-device,
then structure the transcript into meeting notes with an LLM. Built on the
audio/transcription core of [`ref/quill`](../ref/quill), with a SwiftUI
popover UI designed per Apple's fluid-interface principles.

## Pipeline

```
record (mic.caf + system.caf) → transcribe (WhisperKit, on-device)
    → transcript.json / transcript.md → LLM structuring → notes.md
```

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`. The structuring
stage pipes the transcript into a configurable CLI (default `claude -p`) and
writes `notes.md` with Summary / Key points / Decisions / Action items.

## Build & run

```sh
swift build -c release
.build/release/QuillApp
```

Requires macOS 15+ (Core Audio process taps). First recording prompts for
Microphone and System Audio Recording permissions; first transcription
downloads `openai_whisper-small` (~460 MB) once.

## UI

Click the feather in the menu bar:

- **Record button** — the red button doubles as a live level meter (halo
  breathes with your mic). Record dot morphs into a stop square in place.
- **Pipeline banner** — shows transcribing / structuring progress.
- **Session list** — recent recordings with their stage (audio → transcript
  → notes); click one to open the best artifact available.

## Config (`~/.config/quill/config.json`, all optional)

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "whisperkit",
    "languages": ["en", "zh-Hans"]
  },
  "mic_voice_processing": false,
  "on_stop": "my-hook",
  "notes": {
    "enabled": true,
    "command": "claude -p",
    "prompt": "custom structuring prompt…"
  }
}
```

`whisperkit` is the only engine — anything else warns to stderr and the
session's `transcribe.log`, then transcribes with whisperkit anyway.

`transcription.languages` is an allow-set, same semantics as the iOS
sibling's picker: omit or leave empty to auto-detect per recording, one entry
to force it, several to restrict detection to that set (mixed-language
speakers). `zh-Hans`/`zh-Hant` are both `zh` to whisper, so the chosen script
is enforced by ICU transform on the output. Unknown codes warn and are
ignored.

`notes.command` is any stdin→stdout CLI (`claude -p`, `ollama run llama3`,
`llm`…). It runs through a login shell so your PATH applies. A structuring
failure never loses anything — the transcript is already on disk: a missing
command, a non-zero exit, empty output, or a run past 15 minutes all log to
`transcribe.log` and notify, leaving the transcript untouched.
