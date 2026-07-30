<!-- iOS sibling: ../quill-ios (WhisperKit engine, ~100 languages incl. zh;
     this macOS app still runs Parakeet v2 English — swap to WhisperKit or
     Parakeet v3 if multilingual is needed here too). -->
# quill-app

Menu-bar meeting recorder for macOS — record any time, transcribe on-device,
then structure the transcript into meeting notes with an LLM. Built on the
audio/transcription core of [`ref/quill`](../ref/quill), with a SwiftUI
popover UI designed per Apple's fluid-interface principles.

## Pipeline

```
record (mic.caf + system.caf) → transcribe (Parakeet, on-device)
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
downloads the Parakeet models (~600 MB) once.

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
  "transcription": { "enabled": true, "engine": "parakeet" },
  "mic_voice_processing": false,
  "on_stop": "my-hook",
  "notes": {
    "enabled": true,
    "command": "claude -p",
    "prompt": "custom structuring prompt…"
  }
}
```

`notes.command` is any stdin→stdout CLI (`claude -p`, `ollama run llama3`,
`llm`…). It runs through a login shell so your PATH applies. A structuring
failure never loses anything — the transcript is already on disk.
