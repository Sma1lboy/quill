# quill-ios

Local-first voice notes for iPhone. Two flows: **quick take** (one tap from
the bottom dock) and **notes** (create a folder first, record inside it with
pause/resume, attach images). Everything transcribes on-device via
WhisperKit (Whisper small, ~100 languages incl. Chinese) and lands in
`Documents/Recordings/` — visible in the Files app, folders the user owns.

Design language: `../DESIGN.md` (kobe DNA — porcelain/espresso/terracotta,
mono kickers, bracket-chip wordmark). macOS sibling: `../quill-app`.

## Build & deploy

```sh
/tmp/xcodegen/xcodegen/bin/xcodegen generate   # or any xcodegen ≥ 2.35
xcodebuild -project QuillIOS.xcodeproj -scheme QuillIOS \
  -destination "platform=iOS,id=<device-udid>" -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> <path-to-quill.app>
```

Requires iOS 17+. First transcription downloads the Whisper model (~600MB)
with a progress banner; after that everything is offline.

## Session folder contract

```
Documents/Recordings/<yyyy.MM.dd-HHmm>/
  mic.caf          audio — always kept, transcript never replaces it
  meta.json        kind (quick|note), timestamps, duration
  transcript.json  timed segments (canonical, same schema as macOS quill)
  transcript.md    readable render
  images/img-*.jpg photos attached in the note screen
  notes.md         (future) LLM-structured notes — see Roadmap
```

## Settings

- **Languages** — multi-select. Empty = auto-detect per recording; one
  selection forces it; several restrict detection to that set (mixed-language
  speakers). 简体/繁體 are separate chips; whisper only knows "zh", so the
  chosen script is enforced by ICU transform on the output.

## Roadmap (foundations already laid)

- [ ] **Image understanding** — vision pass over `images/` (whiteboards,
      slides) producing captions/extracted text.
- [ ] **LLM structure enhance** — transcript + image understanding →
      `notes.md` (summary / key points / decisions / actions). The
      `EnhanceService` protocol (Sources/Enhance/) is the seam; backend
      candidates: Apple FoundationModels (on-device, iOS 26), Claude API
      (explicit opt-in — leaves the device), or macOS handoff to
      `claude -p`.
- [ ] Playback of mic.caf in the session screen.
- [ ] iCloud/Files sync story for cross-device (Mac sibling reads the same
      folder schema).
