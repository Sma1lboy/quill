# quill-ios

Local-first voice notes for iPhone. Two flows: **quick take** (one tap from
the bottom dock) and **notes** (create a folder first, record inside it with
pause/resume, attach images). Everything transcribes on-device via
WhisperKit (Whisper large-v3 turbo, ~100 languages incl. Chinese) and lands
in `Documents/Recordings/` — visible in the Files app, folders the user owns.

**What leaves the phone.** Audio never does — transcription is WhisperKit,
on-device, with no setting that changes it. Notes are also written
on-device by default (Apple FoundationModels, or the opt-in local Qwen).
The one exception is **remote notes**, off unless the user turns it on and
pastes their own API key: that sends the *transcript text* (plus OCR text
from attached images) to the endpoint they chose, and nothing else. quill
identifies itself honestly to that endpoint — it does not spoof another
client's user-agent to unlock server behavior withheld from third parties.

Remote notes speak either the Anthropic or the OpenAI wire format
(`RemoteShape`), against any base URL — the vendor's own, a proxy, or a
server on the LAN, which covers Ollama / vLLM / LM Studio / OpenRouter and
most relays. The model is free text; `/v1/models` is probed only to suggest
names (cached an hour per endpoint), and an endpoint that doesn't serve a
catalog still works.

Design language: `../DESIGN.md` (kobe DNA — porcelain/espresso/terracotta,
mono kickers, bracket-chip wordmark). macOS sibling: `../quill-app`.

## Build & deploy

```sh
brew install xcodegen && xcodegen generate      # ≥ 2.35; regenerate after
                                                # adding or removing sources
xcodebuild -project QuillIOS.xcodeproj -scheme QuillIOS \
  -destination "platform=iOS,id=<device-udid>" -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> <path-to-quill.app>
```

Requires iOS 17+. First transcription downloads the Whisper model with a
progress banner; after that everything is offline. The default is large-v3
turbo (3.2 GB) — settings offers small (487 MB) and base (147 MB) when
storage is tight. Sizes are measured from the whisperkit-coreml repo and
live in `ModelCatalog`; the picker refuses a download that won't fit.

## Session folder contract

```
Documents/Recordings/<yyyy.MM.dd-HHmm>/
  mic.caf          audio — always kept, transcript never replaces it
  meta.json        kind (quick|note), timestamps, duration
  transcript.json  timed segments (canonical, same schema as macOS quill)
  transcript.md    readable render — written before transcript.json, which
                   is the queue's done-marker
  images/img-*.jpg photos attached in the note screen
  ocr.json         filename → text Vision read off each image; "" means
                   "looked, found nothing" so it isn't re-scanned
  notes.md         LLM-structured notes (the product's primary artifact)
  partial.json     slice checkpoint, transient — removed on success
  transcribe.log   per-session pipeline log
```

Only the recordings are backed up to iCloud. The whisper weights under
`Documents/huggingface/` and the qwen GGUF under `Documents/llm/` are flagged
`isExcludedFromBackup` at every launch — up to 4.3 GB of re-downloadable
files, which would otherwise eat the user's quota and make the backup that
carries their recordings fail. Sessions themselves survive delete-and-
reinstall via iCloud restore, and are visible in Files either way.

`meta.json` keys beyond the recording facts: `title` (generated or renamed
— absent means fall back to the timestamp) and `transcribe_failures` (count
of failed automatic attempts, cleared on success). Every pass merges into
this one file, so writers read-merge-write rather than overwrite.

## Settings

- **Languages** — multi-select. Empty = auto-detect per recording; one
  selection forces it; several restrict detection to that set (mixed-language
  speakers). 简体/繁體 are separate chips; whisper only knows "zh", so the
  chosen script is enforced by ICU transform on the output.

## Roadmap

- [x] **Image understanding** — Vision OCR over `images/`, cached in
      `ocr.json`, fed to the enhance prompt as context (never quoted into
      `notes.md`).
- [x] **LLM structure enhance** — transcript + image text → `notes.md`. The
      `EnhanceService` protocol (Sources/Enhance/) is the seam; the chain is
      Apple FoundationModels (on-device, iOS 26) → local Qwen2.5-1.5B via
      llama.cpp (opt-in ~1 GB download) → give up, with a retry in the
      session screen. Also generates the session title.
- [x] Playback of mic.caf in the session screen — scrub, tap a transcript
      segment to seek, the segment under the playhead marked. Stands down
      while any session is recording (shared AVAudioSession).
- [ ] Cross-device sync. iCloud was investigated and deferred: the folder
      contract is genuinely portable, so share-as-zip + AirDrop already
      moves a session to the Mac. Multi-track mac sessions (mic + system)
      are declined here so the Mac transcribes them properly.
